/*
 * pg_plan_override.c
 *
 * Dynamic per-query planner GUC overrides for PostgreSQL 12+.
 *
 * Intercepts the planner hook, matches queries by queryId or LIKE pattern,
 * temporarily sets GUC overrides during planning, then restores originals.
 */

#include "postgres.h"
#include "fmgr.h"
#include "miscadmin.h"

#include "executor/spi.h"
#include "optimizer/planner.h"
#include "utils/builtins.h"
#include "utils/guc.h"
#include "utils/jsonb.h"
#include "utils/memutils.h"
#include "utils/timestamp.h"

#if PG_VERSION_NUM >= 130000
#include "common/jsonapi.h"
#endif

#if PG_VERSION_NUM < 140000
extern PGDLLIMPORT const char *debug_query_string;
#endif

PG_MODULE_MAGIC;

/* ----------------------------------------------------------------
 * Data structures
 * ---------------------------------------------------------------- */

typedef struct OverrideRule
{
	int64	query_id;		/* 0 if not set */
	char   *query_pattern;	/* NULL if not set */
	char  **guc_names;
	char  **guc_values;
	int		num_gucs;
	int		priority;
} OverrideRule;

/* ----------------------------------------------------------------
 * Static state
 * ---------------------------------------------------------------- */

/* GUC variables */
static bool po_enabled = true;
static bool po_debug = false;
static int  po_cache_ttl = 60;

/* Hook chain */
static planner_hook_type prev_planner_hook = NULL;

/* Rule cache */
static OverrideRule *cached_rules = NULL;
static int           cached_rules_count = 0;
static TimestampTz   cache_loaded_at = 0;
static MemoryContext  cache_context = NULL;

/* Reentrancy guard */
static bool loading_rules = false;

/* ----------------------------------------------------------------
 * Forward declarations
 * ---------------------------------------------------------------- */

void _PG_init(void);

#if PG_VERSION_NUM >= 140000
static PlannedStmt *po_planner(Query *parse, const char *query_string,
							   int cursorOptions, ParamListInfo boundParams);
#else
static PlannedStmt *po_planner(Query *parse, int cursorOptions,
							   ParamListInfo boundParams);
#endif

static void load_rules(void);
static void free_rule_cache(void);

#if PG_VERSION_NUM >= 140000
static OverrideRule *find_matching_rule(Query *parse, const char *query_string);
#else
static OverrideRule *find_matching_rule(Query *parse);
#endif

static bool pattern_match(const char *text, const char *pattern);
static int  parse_jsonb_gucs(Datum jsonb_datum, char ***names_out, char ***values_out,
							 MemoryContext mcxt);

PG_FUNCTION_INFO_V1(pg_plan_override_refresh_cache);

/* ----------------------------------------------------------------
 * Module initialization
 * ---------------------------------------------------------------- */

void
_PG_init(void)
{
	DefineCustomBoolVariable("pg_plan_override.enabled",
							 "Enable pg_plan_override planner hook.",
							 NULL,
							 &po_enabled,
							 true,
							 PGC_USERSET,
							 0,
							 NULL, NULL, NULL);

	DefineCustomBoolVariable("pg_plan_override.debug",
							 "Log when overrides are applied.",
							 NULL,
							 &po_debug,
							 false,
							 PGC_USERSET,
							 0,
							 NULL, NULL, NULL);

	DefineCustomIntVariable("pg_plan_override.cache_ttl",
							"Seconds between rule cache refreshes.",
							NULL,
							&po_cache_ttl,
							60,
							1,
							3600,
							PGC_USERSET,
							GUC_UNIT_S,
							NULL, NULL, NULL);

	/* Install planner hook */
	prev_planner_hook = planner_hook;
	planner_hook = po_planner;
}

/* ----------------------------------------------------------------
 * Planner hook
 * ---------------------------------------------------------------- */

#if PG_VERSION_NUM >= 140000
static PlannedStmt *
po_planner(Query *parse, const char *query_string,
		   int cursorOptions, ParamListInfo boundParams)
#else
static PlannedStmt *
po_planner(Query *parse, int cursorOptions, ParamListInfo boundParams)
#endif
{
	OverrideRule   *rule;
	PlannedStmt	   *result;
	char		  **saved_values = NULL;
	int				i;

	/* Fast path: disabled or reentrancy guard active */
	if (!po_enabled || loading_rules)
	{
		if (prev_planner_hook)
#if PG_VERSION_NUM >= 140000
			return prev_planner_hook(parse, query_string, cursorOptions, boundParams);
#else
			return prev_planner_hook(parse, cursorOptions, boundParams);
#endif
		else
			return standard_planner(parse,
#if PG_VERSION_NUM >= 140000
									query_string,
#endif
									cursorOptions, boundParams);
	}

	/* Refresh cache if TTL expired */
	if (cache_loaded_at == 0 ||
		TimestampDifferenceExceeds(cache_loaded_at,
								  GetCurrentTimestamp(),
								  po_cache_ttl * 1000L))
	{
		load_rules();
	}

	/* Find a matching rule */
#if PG_VERSION_NUM >= 140000
	rule = find_matching_rule(parse, query_string);
#else
	rule = find_matching_rule(parse);
#endif

	/* No match: pass through */
	if (rule == NULL)
	{
		if (prev_planner_hook)
#if PG_VERSION_NUM >= 140000
			return prev_planner_hook(parse, query_string, cursorOptions, boundParams);
#else
			return prev_planner_hook(parse, cursorOptions, boundParams);
#endif
		else
			return standard_planner(parse,
#if PG_VERSION_NUM >= 140000
									query_string,
#endif
									cursorOptions, boundParams);
	}

	/* Save current GUC values */
	saved_values = (char **) palloc(rule->num_gucs * sizeof(char *));
	for (i = 0; i < rule->num_gucs; i++)
	{
		const char *val = GetConfigOption(rule->guc_names[i], false, false);
		saved_values[i] = val ? pstrdup(val) : NULL;
	}

	/* Set override GUC values */
	for (i = 0; i < rule->num_gucs; i++)
	{
		(void) set_config_option(rule->guc_names[i],
								 rule->guc_values[i],
								 PGC_USERSET,
								 PGC_S_SESSION,
								 GUC_ACTION_SET,
								 true, 0, false);
	}

	if (po_debug)
		elog(LOG, "pg_plan_override: applied %d GUC override(s) for query (queryId=%ld)",
			 rule->num_gucs, (long) rule->query_id);

	/* Call planner with overrides in effect, guarantee restore on error */
	PG_TRY();
	{
		if (prev_planner_hook)
#if PG_VERSION_NUM >= 140000
			result = prev_planner_hook(parse, query_string, cursorOptions, boundParams);
#else
			result = prev_planner_hook(parse, cursorOptions, boundParams);
#endif
		else
			result = standard_planner(parse,
#if PG_VERSION_NUM >= 140000
									  query_string,
#endif
									  cursorOptions, boundParams);

		/* Restore original GUC values */
		for (i = 0; i < rule->num_gucs; i++)
		{
			(void) set_config_option(rule->guc_names[i],
									 saved_values[i],
									 PGC_USERSET,
									 PGC_S_SESSION,
									 GUC_ACTION_SET,
									 true, 0, false);
		}
	}
	PG_CATCH();
	{
		/* Restore GUCs even on error */
		for (i = 0; i < rule->num_gucs; i++)
		{
			(void) set_config_option(rule->guc_names[i],
									 saved_values[i],
									 PGC_USERSET,
									 PGC_S_SESSION,
									 GUC_ACTION_SET,
									 true, 0, false);
		}
		PG_RE_THROW();
	}
	PG_END_TRY();

	return result;
}

/* ----------------------------------------------------------------
 * Rule cache loading (via SPI)
 * ---------------------------------------------------------------- */

static void
load_rules(void)
{
	int			ret;
	int			i;
	MemoryContext oldcxt;

	/* Reentrancy guard: SPI queries go through the planner hook too */
	loading_rules = true;

	free_rule_cache();

	/* Create or reset the cache memory context */
	if (cache_context == NULL)
	{
		cache_context = AllocSetContextCreate(TopMemoryContext,
											  "pg_plan_override cache",
											  ALLOCSET_DEFAULT_SIZES);
	}
	else
	{
		MemoryContextReset(cache_context);
	}

	if (SPI_connect() != SPI_OK_CONNECT)
	{
		loading_rules = false;
		elog(WARNING, "pg_plan_override: SPI_connect failed, cache not loaded");
		return;
	}

	/* Check if the rules table exists (extension may not be CREATE'd yet) */
	ret = SPI_execute(
		"SELECT 1 FROM pg_catalog.pg_class c "
		"JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace "
		"WHERE n.nspname = 'plan_override' "
		"AND c.relname = 'override_rules'",
		true, 1);

	if (ret != SPI_OK_SELECT || SPI_processed == 0)
	{
		SPI_finish();
		cache_loaded_at = GetCurrentTimestamp();
		loading_rules = false;
		return;
	}

	ret = SPI_execute(
		"SELECT query_id, query_pattern, gucs, priority "
		"FROM plan_override.override_rules "
		"WHERE enabled "
		"ORDER BY priority DESC",
		true, 0);

	if (ret != SPI_OK_SELECT)
	{
		SPI_finish();
		loading_rules = false;
		elog(WARNING, "pg_plan_override: failed to load rules (SPI error %d)", ret);
		return;
	}

	cached_rules_count = (int) SPI_processed;

	if (cached_rules_count == 0)
	{
		SPI_finish();
		cache_loaded_at = GetCurrentTimestamp();
		loading_rules = false;
		return;
	}

	oldcxt = MemoryContextSwitchTo(cache_context);
	cached_rules = (OverrideRule *) palloc0(cached_rules_count * sizeof(OverrideRule));

	for (i = 0; i < cached_rules_count; i++)
	{
		HeapTuple	tuple = SPI_tuptable->vals[i];
		TupleDesc	tupdesc = SPI_tuptable->tupdesc;
		bool		isnull;
		Datum		datum;
		OverrideRule *rule = &cached_rules[i];

		/* query_id */
		datum = SPI_getbinval(tuple, tupdesc, 1, &isnull);
		rule->query_id = isnull ? 0 : DatumGetInt64(datum);

		/* query_pattern */
		datum = SPI_getbinval(tuple, tupdesc, 2, &isnull);
		if (!isnull)
			rule->query_pattern = pstrdup(TextDatumGetCString(datum));
		else
			rule->query_pattern = NULL;

		/* gucs (JSONB) */
		datum = SPI_getbinval(tuple, tupdesc, 3, &isnull);
		if (!isnull)
			rule->num_gucs = parse_jsonb_gucs(datum,
											  &rule->guc_names,
											  &rule->guc_values,
											  cache_context);
		else
			rule->num_gucs = 0;

		/* priority */
		datum = SPI_getbinval(tuple, tupdesc, 4, &isnull);
		rule->priority = isnull ? 0 : DatumGetInt32(datum);
	}

	MemoryContextSwitchTo(oldcxt);
	SPI_finish();

	cache_loaded_at = GetCurrentTimestamp();
	loading_rules = false;

	if (po_debug)
		elog(LOG, "pg_plan_override: loaded %d rule(s)", cached_rules_count);
}

static void
free_rule_cache(void)
{
	cached_rules = NULL;
	cached_rules_count = 0;
}

/* ----------------------------------------------------------------
 * JSONB GUC parsing
 *
 * Expects a flat JSONB object like {"enable_seqscan": "off", ...}
 * Returns count of key/value pairs; allocates arrays in mcxt.
 * ---------------------------------------------------------------- */

static int
parse_jsonb_gucs(Datum jsonb_datum, char ***names_out, char ***values_out,
				 MemoryContext mcxt)
{
	Jsonb	   *jb = DatumGetJsonbP(jsonb_datum);
	JsonbIterator *it;
	JsonbValue	v;
	JsonbIteratorToken tok;
	int			count = 0;
	int			capacity = 8;
	char	  **names;
	char	  **values;
	MemoryContext oldcxt;
	oldcxt = MemoryContextSwitchTo(mcxt);

	names = (char **) palloc(capacity * sizeof(char *));
	values = (char **) palloc(capacity * sizeof(char *));

	it = JsonbIteratorInit(&jb->root);
	while ((tok = JsonbIteratorNext(&it, &v, false)) != WJB_DONE)
	{
		if (tok == WJB_KEY)
		{
			char *key;

			/* Grow arrays if needed */
			if (count >= capacity)
			{
				capacity *= 2;
				names = (char **) repalloc(names, capacity * sizeof(char *));
				values = (char **) repalloc(values, capacity * sizeof(char *));
			}

			key = pnstrdup(v.val.string.val, v.val.string.len);
			names[count] = key;
		}
		else if (tok == WJB_VALUE)
		{
			char *val;

			if (v.type == jbvString)
				val = pnstrdup(v.val.string.val, v.val.string.len);
			else if (v.type == jbvBool)
				val = pstrdup(v.val.boolean ? "on" : "off");
			else if (v.type == jbvNumeric)
				val = pstrdup(DatumGetCString(DirectFunctionCall1(numeric_out,
								NumericGetDatum(v.val.numeric))));
			else
			{
				/* Skip unsupported types */
				elog(WARNING, "pg_plan_override: skipping non-scalar GUC value for '%s'",
					 names[count]);
				continue;
			}

			values[count] = val;
			count++;
		}
	}

	MemoryContextSwitchTo(oldcxt);

	*names_out = names;
	*values_out = values;
	return count;
}

/* ----------------------------------------------------------------
 * Query matching
 * ---------------------------------------------------------------- */

#if PG_VERSION_NUM >= 140000
static OverrideRule *
find_matching_rule(Query *parse, const char *query_string)
#else
static OverrideRule *
find_matching_rule(Query *parse)
#endif
{
	int		i;
#if PG_VERSION_NUM < 140000
	const char *query_string = debug_query_string;
#endif

	if (cached_rules == NULL || cached_rules_count == 0)
		return NULL;

	/* Pass 1: match by queryId (fast, exact) */
	if (parse->queryId != 0)
	{
		for (i = 0; i < cached_rules_count; i++)
		{
			if (cached_rules[i].query_id != 0 &&
				cached_rules[i].query_id == (int64) parse->queryId)
				return &cached_rules[i];
		}
	}

	/* Pass 2: match by pattern (LIKE-style against query text) */
	if (query_string != NULL)
	{
		for (i = 0; i < cached_rules_count; i++)
		{
			if (cached_rules[i].query_pattern != NULL &&
				pattern_match(query_string, cached_rules[i].query_pattern))
				return &cached_rules[i];
		}
	}

	return NULL;
}

/* ----------------------------------------------------------------
 * Simple LIKE-style pattern matching (% and _ wildcards)
 * ---------------------------------------------------------------- */

static bool
pattern_match(const char *text, const char *pattern)
{
	const char *t = text;
	const char *p = pattern;
	const char *t_backtrack = NULL;
	const char *p_backtrack = NULL;

	while (*t)
	{
		if (*p == '%')
		{
			/* Skip consecutive % */
			while (*p == '%')
				p++;
			if (*p == '\0')
				return true;
			/* Remember backtrack positions */
			p_backtrack = p;
			t_backtrack = t;
		}
		else if (*p == '_' || *p == *t)
		{
			p++;
			t++;
		}
		else if (p_backtrack)
		{
			/* Backtrack: advance text position after last % */
			t_backtrack++;
			t = t_backtrack;
			p = p_backtrack;
		}
		else
		{
			return false;
		}
	}

	/* Skip trailing % in pattern */
	while (*p == '%')
		p++;

	return (*p == '\0');
}

/* ----------------------------------------------------------------
 * SQL-callable: refresh_cache()
 * ---------------------------------------------------------------- */

Datum
pg_plan_override_refresh_cache(PG_FUNCTION_ARGS)
{
	load_rules();
	PG_RETURN_VOID();
}

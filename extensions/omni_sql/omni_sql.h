#ifndef OMNI_SQL_H
#define OMNI_SQL_H
// clang-format off
#include <postgres.h>
#include <fmgr.h>
// clang-format on

#include <funcapi.h>
#include <parser/parser.h>
#include <utils/builtins.h>

#include <nodes/nodeFuncs.h>

#include "deparse.h"

List *omni_sql_parse_statement(char *statement);
List *omni_sql_add_cte(List *stmts, text *cte_name, List *cte_stmts, bool recursive, bool prepend);
bool omni_sql_is_parameterized(List *stmts);

#endif // OMNI_SQL_H
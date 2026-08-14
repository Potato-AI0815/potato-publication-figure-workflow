#!/usr/bin/env Rscript
# resolve_dependencies.R — Potato Publication Figure Workflow v0.2.1-alpha
# 运行时解析 providers: 显式能力契约 + 便携 skill root 发现。
# 发现顺序: 显式 skills root 参数 > $CODEX_HOME/skills > 平台默认目录。
# 解析失败 → NOT_AVAILABLE（绝不猜测）。
#
# 用法:
#   Rscript resolve_dependencies.R [skills_root] [--json] [--contracts <path>]

script_dir <- dirname(normalizePath(sub("^--file=", "",
  commandArgs(FALSE)[grepl("^--file=", commandArgs(FALSE))][1])))
source(file.path(script_dir, "lib", "orchestrator_core.R"))

args <- commandArgs(trailingOnly = TRUE)
explicit_root <- ""
contract_path <- file.path(dirname(script_dir), "provider_contracts.yaml")
as_json <- FALSE
i <- 1
while (i <= length(args)) {
  a <- args[i]
  if (a == "--json") as_json <- TRUE
  else if (a == "--contracts") { i <- i + 1; contract_path <- args[i] }
  else if (!grepl("^--", a) && !nzchar(explicit_root)) explicit_root <- a
  i <- i + 1
}

if (!file.exists(contract_path)) {
  cat(sprintf("ERROR: provider_contracts.yaml not found: %s\n", contract_path), file = stderr())
  quit(status = 3)
}
contracts <- load_provider_contracts(contract_path)
roots <- discover_skills_roots(explicit_root)
res <- resolve_providers(roots, contracts)

if (as_json) {
  if (!requireNamespace("jsonlite", quietly = TRUE)) {
    cat("ERROR: jsonlite unavailable for --json output\n", file = stderr())
    quit(status = 4)
  }
  payload <- list(
    workflow_version = WORKFLOW_VERSION,
    discovery_roots = if (length(res$roots)) res$roots else list("NONE"),
    providers = lapply(names(res$resolved), function(role) {
      m <- res$resolved[[role]]
      if (is.null(m)) list(status = "NOT_AVAILABLE")
      else list(status = "AVAILABLE", name = m$name, version = m$version, path = m$path)
    }) |> setNames(names(res$resolved))
  )
  cat(as.character(jsonlite::toJSON(payload, auto_unbox = TRUE, pretty = TRUE)), "\n")
} else {
  cat("=== Provider Resolution (capability contracts) ===\n")
  cat(sprintf("discovery roots: %s\n",
              if (length(res$roots)) paste(res$roots, collapse = " | ") else "(none exist)"))
  for (role in names(res$resolved)) {
    m <- res$resolved[[role]]
    cat(sprintf("%-22s %s\n", role,
                if (is.null(m)) "NOT_AVAILABLE (never guess)"
                else sprintf("%s (v%s) @ %s", m$name, m$version, m$path)))
  }
  if (is.null(res$resolved$STATISTICS_PROVIDER)) {
    cat("\nNOTE: STATISTICS_PROVIDER unavailable -> use USER_PROVIDED_STATISTICS\n")
    cat("      (statistics_contract.yaml) or STATISTICAL_REVIEW_REQUIRED; never fake PASS.\n")
  }
}
quit(status = 0)

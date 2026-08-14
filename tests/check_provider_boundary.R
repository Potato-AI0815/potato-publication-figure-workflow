#!/usr/bin/env Rscript
# check_provider_boundary.R — v0.2.1-alpha (W2) provider-boundary gate.
# 无 provider 根时全部角色必须 NOT_AVAILABLE（fail-closed，禁止 fake PASS）。
# 用法: Rscript tests/check_provider_boundary.R <workflow_root>
args <- commandArgs(trailingOnly = TRUE)
root <- normalizePath(if (length(args) >= 1) args[1] else ".", mustWork = TRUE)
source(file.path(root, "scripts", "lib", "orchestrator_core.R"))
cts <- load_provider_contracts(file.path(root, "provider_contracts.yaml"))
res <- resolve_providers(roots = character(), contracts = cts)
st <- res[["status"]]
cat("status:", paste(st, collapse = ","), "\n")
if (length(st) == 0 || !all(st == "NOT_AVAILABLE")) quit(status = 1)
cat("PROVIDER_BOUNDARY: all NOT_AVAILABLE confirmed (no fake PASS)\n")

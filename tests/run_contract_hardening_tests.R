#!/usr/bin/env Rscript
# run_contract_hardening_tests.R — v0.2.1-alpha 发布加固对抗性测试
# 覆盖:
#   H1  audit contract version exact-match 矩阵 (R6.1/R6.0/R6.2/R6.999/R6/R6-foo/R7.0/NULL/"")
#   H2  ready invariant 对抗 (PASS_WITH_LIMITED_EVIDENCE + ready=true 阻断)
#   H3  publication package vocabulary (REVISE 拒绝)
#   H4  audited_artifacts bytes 验证 (schema + binding)
#   H5  cross-artifact consistency 单元 (claim/unit/paired)
#   H6  cross-artifact E2E (C5 claim mismatch, C6 unit mismatch)
# 用法: Rscript run_contract_hardening_tests.R <workflow_root> <audit_root>

args <- commandArgs(trailingOnly = TRUE)
root <- normalizePath(if (length(args)) args[1] else ".", mustWork = TRUE)
audit_root <- if (length(args) > 1) normalizePath(args[2], mustWork = TRUE) else ""
source(file.path(root, "scripts", "lib", "orchestrator_core.R"))
## verify_audit_binding 依赖 sha256_file（纯 R SHA-256 后备实现）
sha_src <- file.path(root, "scripts", "lib", "sha256.R")
if (file.exists(sha_src)) source(sha_src)

pass <- 0L; fail <- 0L; failures <- character()
check <- function(name, cond, detail = "") {
  if (isTRUE(cond)) { pass <<- pass + 1L; cat(sprintf("  [PASS] %s\n", name)) }
  else { fail <<- fail + 1L; failures <<- c(failures, sprintf("%s: %s", name, detail)); cat(sprintf("  [FAIL] %s  %s\n", name, detail)) }
}

## ---------- H1: audit contract version exact match ----------
cat("=== H1: contract version exact-match (9) ===\n")
mk_audit_json <- function(contract_version) {
  list(contract_version = contract_version,
       figure_integrity = list(status = "PASS"),
       publication_package = list(status = "PASS"),
       publication_ready = TRUE,
       repair_routes = list(NEXT_ACTION = "NONE"),
       audited_artifacts = list())
}
## 单元级: 直接调 schema_check（audited_artifacts 空会触发 SCHEMA_FAIL, 但版本判断在其后
## —— 先验证版本判断本身: 用带正确 artifacts 的完整 payload 区分版本错误与其他错误
mk_full_audit <- function(cv) {
  list(contract_version = cv,
       figure_integrity = list(status = "PASS"),
       publication_package = list(status = "PASS"),
       publication_ready = TRUE,
       repair_routes = list(NEXT_ACTION = "NONE"),
       audited_artifacts = list(a = list(sha256 = "aa", bytes = 1)))
}
cv_ok <- function(cv) {
  ## 直接调用 schema 层（validate_artifact 需要文件; 这里走纯函数路径）
  schema_check(mk_full_audit(cv), "figure_audit")
}
check("H1a R6.1 -> ACCEPT (NULL)", is.null(cv_ok("R6.1")), cv_ok("R6.1"))
check("H1b R6.0 -> CONTRACT_MISMATCH", grepl("unsupported audit contract_version", cv_ok("R6.0")), cv_ok("R6.0"))
check("H1c R6.2 -> CONTRACT_MISMATCH", grepl("unsupported audit contract_version", cv_ok("R6.2")), cv_ok("R6.2"))
check("H1d R6.999 -> CONTRACT_MISMATCH", grepl("unsupported audit contract_version", cv_ok("R6.999")), cv_ok("R6.999"))
check("H1e R6 -> CONTRACT_MISMATCH", grepl("unsupported audit contract_version", cv_ok("R6")), cv_ok("R6"))
check("H1f R6-foo -> CONTRACT_MISMATCH", grepl("unsupported audit contract_version", cv_ok("R6-foo")), cv_ok("R6-foo"))
check("H1g R7.0 -> CONTRACT_MISMATCH", grepl("unsupported audit contract_version", cv_ok("R7.0")), cv_ok("R7.0"))
check("H1h NULL -> schema failure (legacy)", grepl("legacy audit contract", schema_check(mk_full_audit(NULL), "figure_audit")), schema_check(mk_full_audit(NULL), "figure_audit"))
r1i <- schema_check(mk_full_audit(""), "figure_audit")
check("H1i empty string -> contract failure", grepl("legacy audit contract|unsupported audit contract_version", r1i), r1i)

## ---------- H2: ready invariant ----------
cat("=== H2: ready invariant (4) ===\n")
ri <- function(fi, pp, ready, na) {
  d <- list(contract_version = "R6.1",
            figure_integrity = list(status = fi),
            publication_package = list(status = pp),
            publication_ready = ready,
            repair_routes = list(NEXT_ACTION = na),
            audited_artifacts = list(a = list(sha256 = "aa", bytes = 1)))
  s <- schema_check(d, "figure_audit")
  if (!is.null(s)) return(s)
  semantic_check(d, "figure_audit")
}
check("H2a PASS + PP PASS + NONE + ready -> ACCEPT", is.null(ri("PASS", "PASS", TRUE, "NONE")), ri("PASS", "PASS", TRUE, "NONE"))
check("H2b PASS_WITH_WARNINGS + PP PASS + NONE + ready -> ACCEPT",
      is.null(ri("PASS_WITH_WARNINGS", "PASS", TRUE, "NONE")), ri("PASS_WITH_WARNINGS", "PASS", TRUE, "NONE"))
r2c <- ri("PASS_WITH_LIMITED_EVIDENCE", "PASS", TRUE, "NONE")
check("H2c PASS_WITH_LIMITED_EVIDENCE + ready=true -> SEMANTIC_FAIL",
      grepl("inconsistent audit JSON", r2c), r2c)
r2d <- ri("PASS", "PASS", TRUE, "RETURN_TO_STATISTICS")
check("H2d ready + NEXT_ACTION!=NONE -> SEMANTIC_FAIL", grepl("inconsistent audit JSON", r2d), r2d)

## ---------- H3: publication package vocabulary ----------
cat("=== H3: publication package vocabulary (5) ===\n")
check("H3a PASS valid", is.null(ri("PASS", "PASS", FALSE, "NONE")))
check("H3b INCOMPLETE valid (not ready)", is.null(ri("PASS", "INCOMPLETE", FALSE, "COMPLETE_DELIVERY")))
check("H3c FAIL valid (not ready)", is.null(ri("PASS", "FAIL", FALSE, "FIX_DELIVERY")))
check("H3d NOT_EVALUABLE valid (not ready)", is.null(ri("PASS", "NOT_EVALUABLE", FALSE, "NONE")))
r3e <- ri("PASS", "REVISE", FALSE, "NONE")
check("H3e REVISE -> SCHEMA_FAIL (removed from vocabulary)",
      grepl("outside R6.1 vocabulary", r3e), r3e)

## ---------- H4: audited_artifacts bytes ----------
cat("=== H4: audited_artifacts bytes (5) ===\n")
h4 <- function(aa) {
  schema_check(list(contract_version = "R6.1",
                    figure_integrity = list(status = "PASS"),
                    publication_package = list(status = "PASS"),
                    publication_ready = FALSE,
                    repair_routes = list(NEXT_ACTION = "NONE"),
                    audited_artifacts = aa),
               "figure_audit")
}
check("H4a sha256+bytes both present -> ACCEPT",
      is.null(h4(list(f = list(sha256 = "aa", bytes = 3)))))
r4b <- h4(list(f = list(sha256 = "aa")))
check("H4b missing bytes -> SCHEMA_FAIL", grepl("without numeric bytes", r4b), r4b)
## binding 层: bytes mismatch -> AUDIT_STALE
tmpdir <- tempfile("h4_"); dir.create(tmpdir)
writeBin(charToRaw("abc"), file.path(tmpdir, "f.bin"))
real_sha <- tolower(sha256_file(file.path(tmpdir, "f.bin")))
bind_ok <- verify_audit_binding(
  list(audited_artifacts = list("f.bin" = list(sha256 = real_sha, bytes = 3))), tmpdir)
check("H4c bytes match -> VERIFIED (NULL)", is.null(bind_ok), bind_ok)
bind_bad <- verify_audit_binding(
  list(audited_artifacts = list("f.bin" = list(sha256 = real_sha, bytes = 999))), tmpdir)
check("H4d bytes mismatch -> AUDIT_STALE (byte-size mismatch)",
      grepl("byte-size mismatch", bind_bad), bind_bad)
bind_bad2 <- verify_audit_binding(
  list(audited_artifacts = list("f.bin" = list(sha256 = "deadbeef", bytes = 999))), tmpdir)
check("H4e sha+bytes both mismatch -> reports sha first",
      grepl("sha256 and byte-size mismatch", bind_bad2), bind_bad2)

## ---------- H5: cross-artifact consistency 单元 ----------
cat("=== H5: cross-artifact consistency unit (8) ===\n")
mk_mission <- function(claim = "SPATS2 binding alters RNA processing.", unit = "patient", pd = "paired") {
  list(figure_id = "fig_2", central_claim = claim, statistical_unit = unit,
       biological_unit = unit, paired_design = pd, primary_contrast = "A vs B")
}
mk_stats <- function(claim = "", unit = "patient", paired = "paired") {
  list(statistical_unit = unit, biological_unit = unit, paired = paired,
       group_definition = "A vs B", status = "PASS")
}
mk_spine <- function(fid = "fig_2", claim = "SPATS2 binding alters RNA processing.", align = "CONFIRMED") {
  list(meta = list(figure_id = fid, central_claim = claim, alignment = align), body = "ok")
}
cc1 <- check_cross_artifact_consistency(mk_mission(), mk_stats(), mk_spine())
check("H5a all consistent -> PASS", identical(cc1$status, "PASS"), cc1$status)
cc2 <- check_cross_artifact_consistency(
  mk_mission(claim = "SPATS2 binding alters RNA processing."),
  mk_stats(), mk_spine(claim = "SPATS2 directly drives EMD."))
check("H5b central_claim mismatch -> FAIL", identical(cc2$status, "FAIL") &&
        grepl("central_claim mismatch", cc2$reason), paste(cc2$status, cc2$reason))
cc3 <- check_cross_artifact_consistency(
  mk_mission(unit = "patient"), mk_stats(unit = "cell"), mk_spine())
check("H5c statistical_unit mismatch -> FAIL (patient vs cell)",
      identical(cc3$status, "FAIL") && grepl("statistical_unit mismatch", cc3$reason),
      paste(cc3$status, cc3$reason))
cc4 <- check_cross_artifact_consistency(
  mk_mission(unit = "patient"), mk_stats(unit = "mouse"), mk_spine())
check("H5d statistical_unit mismatch -> FAIL (patient vs mouse)",
      identical(cc4$status, "FAIL") && grepl("statistical_unit mismatch", cc4$reason),
      paste(cc4$status, cc4$reason))
cc5 <- check_cross_artifact_consistency(
  mk_mission(unit = "Patient"), mk_stats(unit = " patient "), mk_spine())
check("H5e normalization: Patient vs ' patient ' -> PASS",
      identical(cc5$status, "PASS"), cc5$status)
cc6 <- check_cross_artifact_consistency(
  mk_mission(pd = "paired"), mk_stats(paired = "unpaired"), mk_spine())
check("H5f paired vs unpaired -> FAIL", identical(cc6$status, "FAIL") &&
        grepl("paired_design mismatch", cc6$reason), paste(cc6$status, cc6$reason))
cc7 <- check_cross_artifact_consistency(
  mk_mission(), mk_stats(), mk_spine(fid = "fig_3"))
check("H5g figure_id mismatch -> FAIL", identical(cc7$status, "FAIL") &&
        grepl("figure_id mismatch", cc7$reason), paste(cc7$status, cc7$reason))
cc8 <- check_cross_artifact_consistency(
  mk_mission(claim = "A"), mk_stats(), mk_spine(claim = "A", align = "REVISED"))
check("H5h alignment=REVISED + same claim -> consistency still PASS (alignment handled elsewhere)",
      identical(cc8$status, "PASS"), cc8$status)

## ---------- H6: cross-artifact E2E（真实 run_workflow + 真实审计）----------
cat("=== H6: cross-artifact E2E (C5/C6) ===\n")
wf_script <- file.path(root, "scripts", "run_workflow.R")
have_jsonlite <- requireNamespace("jsonlite", quietly = TRUE)
run_wf <- function(proj, extra_args = character()) {
  a <- c("--vanilla", shQuote(wf_script), shQuote(proj), "--json")
  if (nzchar(audit_root)) a <- c(a, "--skills-root", shQuote(dirname(audit_root)))
  a <- c(a, extra_args)
  out <- suppressWarnings(system2(file.path(R.home("bin"), "Rscript"), a, stdout = TRUE, stderr = ""))
  rc <- attr(out, "status"); if (is.null(rc)) rc <- 0L
  js <- NULL
  if (have_jsonlite) js <- tryCatch(jsonlite::fromJSON(paste(out, collapse = "\n"),
                                                       simplifyVector = FALSE),
                                    error = function(e) NULL)
  list(rc = as.integer(rc), json = js, raw = paste(out, collapse = " "))
}
mk_project <- function(claim_m, claim_s, unit_m, unit_s, fid = "TEST1") {
  d <- tempfile("proj_"); dir.create(file.path(d, "figure"), recursive = TRUE)
  ## 从 audit 的 ready_case 复制可审计 figure（manifest + png + contract + source_data）
  ready_case <- file.path(audit_root, "tests", "main_entry_fixtures", "ready_case")
  if (dir.exists(ready_case)) {
    invisible(file.copy(list.files(ready_case, full.names = TRUE),
                        file.path(d, "figure"), recursive = TRUE))
    unlink(file.path(d, "figure", "figure_audit.json"))
  }
  writeLines(c(sprintf("figure_id: %s", fid),
               sprintf("central_claim: \"%s\"", claim_m),
               "evidence_role: primary",
               "biological_unit: patient",
               sprintf("statistical_unit: %s", unit_m),
               "primary_contrast: SDC1 High vs Low",
               "status: LOCKED"), file.path(d, "figure_mission.yaml"))
  writeLines(c("biological_unit: patient",
               sprintf("statistical_unit: %s", unit_s),
               "group_definition: High vs Low (median split)",
               "paired: false",
               "test: log-rank",
               "descriptive_vs_inferential: inferential",
               "status: PASS",
               "n_by_group:",
               "  High: 381",
               "  Low: 382"), file.path(d, "statistics_contract.yaml"))
  writeLines(c("---",
               sprintf("figure_id: %s", fid),
               sprintf("central_claim: \"%s\"", claim_s),
               "alignment: CONFIRMED",
               "date: 2026-08-14",
               "---", "",
               "Figure supports the central claim."),
             file.path(d, "paper_spine_final.md"))
  d
}
if (nzchar(audit_root) && file.exists(wf_script)) {
  ## C5: central claim mismatch（真实 E2E: 审计 → spine claim 被改 → CROSS_ARTIFACT_MISMATCH）
  d5 <- mk_project("SDC1-high tumors show worse survival",
                   "SDC1-high tumors show better survival", "patient", "patient")
  r5 <- run_wf(d5, extra_args = "--invoke-audit")
  t5 <- if (is.null(r5$json)) r5$raw else paste(r5$raw, collapse = " ")
  check("C5a claim mismatch -> CROSS_ARTIFACT_MISMATCH", grepl("CROSS_ARTIFACT_MISMATCH", t5), t5)
  check("C5b claim mismatch -> FINAL_FIGURE_READY=false",
        isTRUE(r5$json$FINAL_FIGURE_READY == FALSE), as.character(r5$json$FINAL_FIGURE_READY))
  check("C5c reason central_claim mismatch", grepl("central_claim mismatch", t5), t5)
  ## 修复 claim -> 恢复
  d5ok <- mk_project("SDC1-high tumors show worse survival",
                     "SDC1-high tumors show worse survival", "patient", "patient")
  r5ok <- run_wf(d5ok, extra_args = "--invoke-audit")
  check("C5d after claim fix -> no cross mismatch",
        !grepl("CROSS_ARTIFACT_MISMATCH", r5ok$raw), r5ok$raw)
  ## C6: statistical unit mismatch
  ## 场景 A: mission=patient, stats=cell → stats 语义层先拦截（伪重复单元）→ RETURN_TO_STATISTICS
  d6 <- mk_project("SDC1-high tumors show worse survival",
                   "SDC1-high tumors show worse survival", "patient", "cell")
  r6 <- run_wf(d6, extra_args = "--invoke-audit")
  t6 <- if (is.null(r6$json)) r6$raw else paste(r6$raw, collapse = " ")
  check("C6a unit mismatch (patient vs cell) -> fail-closed (pseudoreplication)",
        grepl("SEMANTIC_FAIL|pseudoreplication", t6), t6)
  check("C6b reason statistical_unit pseudoreplication", grepl("pseudoreplication", t6), t6)
  ## 场景 B: mission=patient, stats=mouse（均非伪重复, 语义层放行 → cross gate 拦截）
  d6b <- mk_project("SDC1-high tumors show worse survival",
                    "SDC1-high tumors show worse survival", "patient", "mouse")
  r6b <- run_wf(d6b, extra_args = "--invoke-audit")
  t6b <- if (is.null(r6b$json)) r6b$raw else paste(r6b$raw, collapse = " ")
  check("C6c unit mismatch (patient vs mouse) -> CROSS_ARTIFACT_MISMATCH",
        grepl("CROSS_ARTIFACT_MISMATCH", t6b), t6b)
  check("C6d reason statistical_unit mismatch", grepl("statistical_unit mismatch", t6b), t6b)
  ## 修复 unit -> 恢复
  d6ok <- mk_project("SDC1-high tumors show worse survival",
                     "SDC1-high tumors show worse survival", "patient", "patient")
  r6ok <- run_wf(d6ok, extra_args = "--invoke-audit")
  check("C6e after unit fix -> no cross mismatch",
        !grepl("CROSS_ARTIFACT_MISMATCH", r6ok$raw), r6ok$raw)
} else {
  for (nm in c("C5a", "C5b", "C5c", "C5d", "C6a", "C6b", "C6c", "C6d", "C6e"))
    check(nm, FALSE, "no audit root or workflow script")
}

cat("\n=== RESULTS ===\n")
cat(sprintf("PASS: %d  FAIL: %d\n", pass, fail))
if (length(failures)) { cat("FAILURES:\n"); for (x in failures) cat(" -", x, "\n") }
quit(status = if (fail == 0L) 0 else 1)

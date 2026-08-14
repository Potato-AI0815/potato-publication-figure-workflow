#!/usr/bin/env Rscript
# run_orchestrator_tests.R — Potato Publication Figure Workflow v0.2.1-alpha (W2)
# 行为级测试（真实子进程 + 临时夹具; 不再做静态文档断言）:
#   O1 反模糊误配: humanizer/suite/audit-named 假 skill 不得抢占角色
#   O2 空 root → 全部 NOT_AVAILABLE（绝不猜测）
#   O3 验证链单元: FILE_MISSING / PARSE_FAIL / SCHEMA_FAIL / SEMANTIC_FAIL / ACCEPT
#   O4 legacy audit JSON → CONTRACT_MISMATCH, workflow exit 2
#   O5 E2E --invoke-audit ready → exit 0, FINAL_FIGURE_READY=true（真实审计调用）
#   O6 E2E fail-closed → exit 2（统计缺陷路由 RETURN_TO_STATISTICS）
#   O7 非法项目目录 → exit 3
#   O8 resolve_dependencies.R CLI 契约
#   O9 对抗性反例: status FAIL/DRAFT、"hello" spine、stale audit + 强制重审、
#      ready+NEXT_ACTION 矛盾、枚举外状态、对抗性转义 JSON、figure_id 不一致
# 用法:
#   Rscript tests/run_orchestrator_tests.R <workflow_root> <audit_skill_root>
#   <audit_skill_root> 指向已安装的 potato-figure-audit（O5/O6/O9 真实调用必需）。

args <- commandArgs(trailingOnly = TRUE)
root <- normalizePath(if (length(args) >= 1) args[1] else ".", mustWork = TRUE)
audit_root <- if (length(args) >= 2) normalizePath(args[2], mustWork = TRUE) else ""

rscript_bin <- file.path(R.home("bin"), "Rscript")
core_path <- file.path(root, "scripts", "lib", "orchestrator_core.R")
wf_script <- file.path(root, "scripts", "run_workflow.R")
rd_script <- file.path(root, "scripts", "resolve_dependencies.R")
stopifnot(file.exists(core_path), file.exists(wf_script), file.exists(rd_script))
source(core_path)
source(file.path(root, "scripts", "lib", "sha256.R"))

pass <- 0L; fail <- 0L
check <- function(name, ok, detail = "") {
  ok <- isTRUE(ok)
  if (ok) { pass <<- pass + 1L; cat(sprintf("PASS %s %s\n", name, detail)) }
  else    { fail <<- fail + 1L; cat(sprintf("FAIL %s %s\n", name, detail)) }
}

have_jsonlite <- requireNamespace("jsonlite", quietly = TRUE)

## 运行 workflow 子进程, 返回 list(rc, json)
run_wf <- function(proj, extra_args = character(), skills_root = "") {
  a <- c("--vanilla", shQuote(wf_script), shQuote(proj), "--json")
  if (nzchar(skills_root)) a <- c(a, "--skills-root", shQuote(skills_root))
  a <- c(a, extra_args)
  out <- suppressWarnings(system2(rscript_bin, a, stdout = TRUE, stderr = ""))
  rc <- attr(out, "status"); if (is.null(rc)) rc <- 0L
  js <- NULL
  if (have_jsonlite) js <- tryCatch(jsonlite::fromJSON(paste(out, collapse = "\n"),
                                                       simplifyVector = FALSE),
                                    error = function(e) NULL)
  list(rc = as.integer(rc), json = js, raw = out)
}

## 生成假 skill 目录
write_fake_skill <- function(dir, name, description) {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  writeLines(c("---",
               sprintf("name: %s", name),
               sprintf("description: %s", description),
               "version: 9.9.9",
               "---", "", sprintf("# %s", name)),
             file.path(dir, "SKILL.md"))
}

## 有效的 mission / statistics / spine 工件（v0.2.1-alpha 契约:
## mission.status=LOCKED, statistics.status=PASS, spine 需机器可读 frontmatter）
write_valid_artifacts <- function(proj) {
  writeLines(c("figure_id: TEST1",
               "central_claim: SDC1-high tumors show worse survival",
               "evidence_role: primary",
               "biological_unit: patient",
               "statistical_unit: patient",
               "primary_contrast: SDC1 High vs Low",
               "status: LOCKED"),
             file.path(proj, "figure_mission.yaml"))
  writeLines(c("biological_unit: patient",
               "statistical_unit: patient",
               "group_definition: High vs Low (median split)",
               "paired: false",
               "test: log-rank",
               "descriptive_vs_inferential: inferential",
               "status: PASS",
               "n_by_group:",
               "  High: 381",
               "  Low: 382"),
             file.path(proj, "statistics_contract.yaml"))
  writeLines(c("---",
               "figure_id: TEST1",
               "central_claim: SDC1-high tumors show worse survival",
               "alignment: CONFIRMED",
               "date: 2026-08-14",
               "---", "",
               "Figure supports the central claim; no overclaim detected."),
             file.path(proj, "paper_spine_final.md"))
}

tmp_base <- file.path(tempdir(), "orch_tests")
unlink(tmp_base, recursive = TRUE)
dir.create(tmp_base, recursive = TRUE)

contracts <- load_provider_contracts(file.path(root, "provider_contracts.yaml"))

## ================= O1 反模糊误配 =================
fake_root1 <- file.path(tmp_base, "fake_root1")
write_fake_skill(file.path(fake_root1, "humanizer"),
                 "humanizer",
                 "Rewrites manuscript text to sound more human; paper and manuscript polishing service.")
write_fake_skill(file.path(fake_root1, "awesome-figure-suite"),
                 "awesome-figure-suite",
                 "All-in-one figure plot panel rendering bundle for papers.")
write_fake_skill(file.path(fake_root1, "figure-audit-pro"),
                 "figure-audit-pro",
                 "Audit figures for plot panel rendering quality; checks figures carefully.")

res1 <- resolve_providers(fake_root1, contracts)
check("O1a humanizer root: STATISTICS NOT_AVAILABLE",
      is.null(res1$resolved$STATISTICS_PROVIDER))
check("O1b suite+audit-named rejected as FIGURE_GENERATOR",
      is.null(res1$resolved$FIGURE_GENERATOR),
      if (is.null(res1$resolved$FIGURE_GENERATOR)) "never guess" else res1$resolved$FIGURE_GENERATOR$name)
check("O1c humanizer did NOT steal PAPER_SPINE",
      is.null(res1$resolved$PAPER_SPINE_PROVIDER) ||
        res1$resolved$PAPER_SPINE_PROVIDER$name != "humanizer")
check("O1d capability path alive: FIGURE_AUDITOR matched by tokens",
      !is.null(res1$resolved$FIGURE_AUDITOR),
      if (is.null(res1$resolved$FIGURE_AUDITOR)) "none" else res1$resolved$FIGURE_AUDITOR$name)

write_fake_skill(file.path(fake_root1, "paper-spine"),
                 "paper-spine",
                 "Manuscript spine: central claim and evidence alignment for papers.")
write_fake_skill(file.path(fake_root1, "nature-statistics"),
                 "nature-statistics",
                 "Statistical analysis contracts for publication figures.")
res1b <- resolve_providers(fake_root1, contracts)
check("O1e real paper-spine wins over humanizer",
      !is.null(res1b$resolved$PAPER_SPINE_PROVIDER) &&
        res1b$resolved$PAPER_SPINE_PROVIDER$name == "paper-spine")
check("O1f preferred-name statistics resolved",
      !is.null(res1b$resolved$STATISTICS_PROVIDER) &&
        res1b$resolved$STATISTICS_PROVIDER$name == "nature-statistics")

## ================= O2 空 root → NOT_AVAILABLE =================
empty_root <- file.path(tmp_base, "empty_root")
dir.create(empty_root, recursive = TRUE, showWarnings = FALSE)
res2 <- resolve_providers(empty_root, contracts)
check("O2a empty root: all four roles NOT_AVAILABLE",
      all(vapply(res2$resolved, is.null, logical(1))),
      sprintf("%d/4 null", sum(vapply(res2$resolved, is.null, logical(1)))))
check("O2b empty root: no roots hallucinated",
      identical(res2$roots, empty_root))

## ================= O3 验证链单元 =================
## FILE_MISSING
v <- validate_artifact(file.path(tmp_base, "nope_mission.yaml"), "figure_mission")
check("O3a FILE_MISSING", v$status == "FILE_MISSING")

## PARSE_FAIL (JSON)
bad_json <- file.path(tmp_base, "bad.json")
writeLines("{ this is not json", bad_json)
v <- validate_artifact(bad_json, "figure_audit")
check("O3b PARSE_FAIL invalid JSON", v$status == "PARSE_FAIL")

## PARSE_FAIL (YAML: only comments)
bad_yaml <- file.path(tmp_base, "bad.yaml")
writeLines(c("# only", "# comments"), bad_yaml)
v <- validate_artifact(bad_yaml, "statistics_contract")
check("O3c PARSE_FAIL unparseable YAML", v$status == "PARSE_FAIL")

## SCHEMA_FAIL legacy audit contract
legacy_json <- file.path(tmp_base, "legacy_audit.json")
writeLines('{"verdict":"PASS","domain_status":{"SCIENTIFIC":"PASS","VISUAL":"PASS"}}',
           legacy_json)
v <- validate_artifact(legacy_json, "figure_audit")
check("O3d SCHEMA_FAIL legacy audit verdict",
      v$status == "SCHEMA_FAIL" && grepl("legacy", v$detail))

## SCHEMA_FAIL missing fields (statistics)
missing_stats <- file.path(tmp_base, "missing_stats.yaml")
writeLines(c("biological_unit: patient"), missing_stats)
v <- validate_artifact(missing_stats, "statistics_contract")
check("O3e SCHEMA_FAIL missing statistics fields",
      v$status == "SCHEMA_FAIL" && grepl("statistical_unit", v$detail))

## SEMANTIC_FAIL pseudoreplication unit
pseudo_stats <- file.path(tmp_base, "pseudo_stats.yaml")
writeLines(c("biological_unit: patient", "statistical_unit: cells",
             "group_definition: g", "paired: false", "test: t",
             "descriptive_vs_inferential: descriptive",
             "status: PASS"), pseudo_stats)
v <- validate_artifact(pseudo_stats, "statistics_contract")
check("O3f SEMANTIC_FAIL pseudoreplication unit",
      v$status == "SEMANTIC_FAIL" && grepl("pseudoreplication", v$detail))

## SEMANTIC_FAIL n_by_group zero
zero_n_stats <- file.path(tmp_base, "zero_n_stats.yaml")
writeLines(c("biological_unit: patient", "statistical_unit: patient",
             "group_definition: g", "paired: false", "test: t",
             "descriptive_vs_inferential: inferential", "status: PASS",
             "n_by_group:", "  High: 0", "  Low: 382"), zero_n_stats)
v <- validate_artifact(zero_n_stats, "statistics_contract")
check("O3g SEMANTIC_FAIL n_by_group < 1",
      v$status == "SEMANTIC_FAIL" && grepl("n_by_group", v$detail) && grepl("High", v$detail))

## SEMANTIC_FAIL mission pseudo unit
pseudo_mission <- file.path(tmp_base, "pseudo_mission.yaml")
writeLines(c("figure_id: X", "central_claim: c", "evidence_role: primary",
             "biological_unit: patient", "statistical_unit: images",
             "primary_contrast: a vs b", "status: LOCKED"), pseudo_mission)
v <- validate_artifact(pseudo_mission, "figure_mission")
check("O3h SEMANTIC_FAIL mission pseudo unit",
      v$status == "SEMANTIC_FAIL" && grepl("pseudoreplication", v$detail))

## ACCEPT mission + statistics
ok_mission <- file.path(tmp_base, "ok_mission.yaml")
writeLines(c("figure_id: X", "central_claim: claim here", "evidence_role: primary",
             "biological_unit: patient", "statistical_unit: patient",
             "primary_contrast: a vs b", "status: LOCKED"), ok_mission)
v <- validate_artifact(ok_mission, "figure_mission")
check("O3i ACCEPT mission", v$status == "ACCEPT")
ok_stats <- file.path(tmp_base, "ok_stats.yaml")
writeLines(c("biological_unit: patient", "statistical_unit: patient",
             "group_definition: g", "paired: false", "test: t",
             "descriptive_vs_inferential: inferential", "status: PASS",
             "n_by_group:", "  High: 381", "  Low: 382"), ok_stats)
v <- validate_artifact(ok_stats, "statistics_contract")
check("O3j ACCEPT statistics (nested n_by_group parsed)", v$status == "ACCEPT")

## SCHEMA_FAIL R6.1 without NEXT_ACTION
no_na_json <- file.path(tmp_base, "no_next_action.json")
writeLines('{"contract_version":"R6.1","figure_integrity":{"status":"PASS"},"publication_package":{"status":"PASS"},"publication_ready":true,"repair_routes":{}}',
           no_na_json)
v <- validate_artifact(no_na_json, "figure_audit")
check("O3k SCHEMA_FAIL missing NEXT_ACTION",
      v$status == "SCHEMA_FAIL" && grepl("NEXT_ACTION", v$detail))

## SEMANTIC_FAIL ready=true but FI=FAIL
inconsistent_json <- file.path(tmp_base, "inconsistent_audit.json")
writeLines('{"contract_version":"R6.1","figure_integrity":{"status":"FAIL"},"publication_package":{"status":"PASS"},"publication_ready":true,"audited_artifacts":{"figure.png":{"sha256":"ab","bytes":1}},"repair_routes":{"NEXT_ACTION":"RETURN_TO_STATISTICS"}}',
           inconsistent_json)
v <- validate_artifact(inconsistent_json, "figure_audit")
check("O3l SEMANTIC_FAIL ready/inconsistent FI",
      v$status == "SEMANTIC_FAIL" && grepl("inconsistent", v$detail))

## SCHEMA_FAIL audited_artifacts 缺失（新鲜度绑定为必备字段）
no_binding_json <- file.path(tmp_base, "no_binding_audit.json")
writeLines('{"contract_version":"R6.1","figure_integrity":{"status":"PASS"},"publication_package":{"status":"PASS"},"publication_ready":true,"repair_routes":{"NEXT_ACTION":"NONE"}}',
           no_binding_json)
v <- validate_artifact(no_binding_json, "figure_audit")
check("O3m SCHEMA_FAIL missing audited_artifacts binding",
      v$status == "SCHEMA_FAIL" && grepl("audited_artifacts", v$detail))

## SCHEMA_FAIL R6.1 状态枚举外（figure_integrity.status="GOOD"）
bad_enum_json <- file.path(tmp_base, "bad_enum_audit.json")
writeLines('{"contract_version":"R6.1","figure_integrity":{"status":"GOOD"},"publication_package":{"status":"PASS"},"publication_ready":false,"audited_artifacts":{"figure.png":{"sha256":"ab","bytes":1}},"repair_routes":{"NEXT_ACTION":"REVISE_FIGURE"}}',
           bad_enum_json)
v <- validate_artifact(bad_enum_json, "figure_audit")
check("O3n SCHEMA_FAIL figure_integrity.status outside R6.1 enum",
      v$status == "SCHEMA_FAIL" && grepl("vocabulary", v$detail))

## SEMANTIC_FAIL ready=true 但 NEXT_ACTION 非 NONE（矛盾契约）
contra_json <- file.path(tmp_base, "contradiction_audit.json")
writeLines('{"contract_version":"R6.1","figure_integrity":{"status":"PASS"},"publication_package":{"status":"PASS"},"publication_ready":true,"audited_artifacts":{"figure.png":{"sha256":"ab","bytes":1}},"repair_routes":{"NEXT_ACTION":"RETURN_TO_STATISTICS"}}',
           contra_json)
v <- validate_artifact(contra_json, "figure_audit")
check("O3o SEMANTIC_FAIL ready=true + NEXT_ACTION=RETURN_TO_STATISTICS",
      v$status == "SEMANTIC_FAIL" && grepl("NEXT_ACTION", v$detail))

## ================= O4 legacy audit E2E → CONTRACT_MISMATCH =================
fixtures <- file.path(audit_root, "tests", "main_entry_fixtures")
ready_case <- file.path(fixtures, "ready_case")
stat_fail_case <- file.path(fixtures, "stat_fail_case")
e2e_possible <- nzchar(audit_root) && dir.exists(ready_case) && dir.exists(stat_fail_case)
if (!e2e_possible) {
  cat(sprintf("NOTE: audit fixtures not found (audit_root='%s'); O5/O6 fail-closed requirement NOT verified.\n", audit_root))
}

proj4 <- file.path(tmp_base, "proj_legacy")
dir.create(file.path(proj4, "figure"), recursive = TRUE, showWarnings = FALSE)
if (dir.exists(ready_case)) {
  invisible(file.copy(list.files(ready_case, full.names = TRUE),
                      file.path(proj4, "figure"), recursive = TRUE))
}
unlink(file.path(proj4, "figure", "figure_audit.json"))
write_valid_artifacts(proj4)
writeLines('{"verdict":"PASS","domain_status":{"SCIENTIFIC":"PASS","VISUAL":"PASS"}}',
           file.path(proj4, "figure", "figure_audit.json"))
Sys.setenv(POTATO_SKILLS_NO_FALLBACK = "1")
r4 <- run_wf(proj4, skills_root = empty_root)
check("O4a legacy audit JSON → exit 2", r4$rc == 2L, sprintf("exit=%d", r4$rc))
check("O4b FIGURE_AUDIT=CONTRACT_MISMATCH",
      !is.null(r4$json) && identical(r4$json$stages$FIGURE_AUDIT, "CONTRACT_MISMATCH"),
      if (is.null(r4$json)) "no json" else as.character(r4$json$stages$FIGURE_AUDIT))
check("O4c FINAL_FIGURE_READY false",
      !is.null(r4$json) && identical(r4$json$FINAL_FIGURE_READY, FALSE))

## ================= O5 E2E ready → exit 0 =================
if (e2e_possible) {
  proj5 <- file.path(tmp_base, "proj_ready")
  dir.create(file.path(proj5, "figure"), recursive = TRUE, showWarnings = FALSE)
  invisible(file.copy(list.files(ready_case, full.names = TRUE),
                      file.path(proj5, "figure"), recursive = TRUE))
  unlink(file.path(proj5, "figure", "figure_audit.json"))
  write_valid_artifacts(proj5)
  r5 <- run_wf(proj5, extra_args = "--invoke-audit",
               skills_root = dirname(audit_root))
  check("O5a E2E ready → exit 0", r5$rc == 0L, sprintf("exit=%d", r5$rc))
  check("O5b FINAL_FIGURE_READY true",
        !is.null(r5$json) && identical(r5$json$FINAL_FIGURE_READY, TRUE))
  check("O5c FIGURE_AUDIT=PASS via real audit invocation",
        !is.null(r5$json) && identical(r5$json$stages$FIGURE_AUDIT, "PASS"))
  check("O5d FIGURE_REVISION=NOT_REQUIRED",
        !is.null(r5$json) && identical(r5$json$stages$FIGURE_REVISION, "NOT_REQUIRED"))
  check("O5e auditor provider = potato-figure-audit",
        !is.null(r5$json) && grepl("potato-figure-audit",
                                   as.character(r5$json$providers$FIGURE_AUDITOR)))
  check("O5f audit_contract publication_ready true",
        !is.null(r5$json) && isTRUE(r5$json$audit_contract$publication_ready))
  ws <- readLines(file.path(proj5, "workflow_state.yaml"), warn = FALSE)
  check("O5g workflow_state.yaml records ready=true",
        any(grepl("^final\\.FINAL_FIGURE_READY: true$", ws)))
} else {
  for (nm in c("O5a", "O5b", "O5c", "O5d", "O5e", "O5f", "O5g")) {
    check(nm, FALSE, "audit skill root / fixtures missing (required for release evidence)")
  }
}

## ================= O6 E2E fail-closed =================
if (e2e_possible) {
  proj6 <- file.path(tmp_base, "proj_statfail")
  dir.create(file.path(proj6, "figure"), recursive = TRUE, showWarnings = FALSE)
  invisible(file.copy(list.files(stat_fail_case, full.names = TRUE),
                      file.path(proj6, "figure"), recursive = TRUE))
  unlink(file.path(proj6, "figure", "figure_audit.json"))
  write_valid_artifacts(proj6)
  r6 <- run_wf(proj6, extra_args = "--invoke-audit",
               skills_root = dirname(audit_root))
  check("O6a E2E stat-fail → exit 2", r6$rc == 2L, sprintf("exit=%d", r6$rc))
  check("O6b FINAL_FIGURE_READY false",
        !is.null(r6$json) && identical(r6$json$FINAL_FIGURE_READY, FALSE))
  check("O6c STATISTICS contract still PASS (defect is in the figure, not the contract)",
        !is.null(r6$json) && identical(r6$json$stages$STATISTICS, "PASS"))
  fi6 <- if (is.null(r6$json)) "" else as.character(r6$json$stages$FIGURE_AUDIT)
  check("O6d FIGURE_AUDIT not PASS (fail-closed)",
        nzchar(fi6) && !fi6 %in% c("PASS"), fi6)
  ra6 <- if (is.null(r6$json)) "" else paste(unlist(r6$json$routing_advice), collapse = " ")
  check("O6e routing advice RETURN_TO_STATISTICS",
        grepl("RETURN_TO_STATISTICS", ra6))
} else {
  for (nm in c("O6a", "O6b", "O6c", "O6d", "O6e")) {
    check(nm, FALSE, "audit skill root / fixtures missing (required for release evidence)")
  }
}

## ================= O7 非法输入 → exit 3 =================
## stdout="" 时 system2 直接以不可见整数返回退出码（无 status 属性）
rc7 <- suppressWarnings(system2(rscript_bin,
  c("--vanilla", shQuote(wf_script), shQuote(file.path(tmp_base, "NO_SUCH_DIR_xyz"))),
  stdout = "", stderr = ""))
rc7 <- if (is.null(rc7)) 0L else as.integer(rc7)
check("O7 nonexistent project dir → exit 3", rc7 == 3L, sprintf("exit=%d", rc7))

## ================= O8 resolve_dependencies CLI =================
out8 <- suppressWarnings(system2(rscript_bin,
  c("--vanilla", shQuote(rd_script), shQuote(fake_root1), "--json"),
  stdout = TRUE, stderr = ""))
rc8 <- attr(out8, "status"); if (is.null(rc8)) rc8 <- 0L
check("O8a resolve_dependencies exit 0", rc8 == 0L, sprintf("exit=%d", rc8))
j8 <- if (have_jsonlite) tryCatch(jsonlite::fromJSON(paste(out8, collapse = "\n"),
                                                      simplifyVector = FALSE),
                                  error = function(e) NULL) else NULL
check("O8b CLI JSON parseable with providers block",
      !is.null(j8) && !is.null(j8$providers),
      if (is.null(j8)) "no json" else paste(names(j8$providers), collapse = ","))
check("O8c CLI resolves paper-spine from fake root",
      !is.null(j8) && identical(j8$providers$PAPER_SPINE_PROVIDER$status, "AVAILABLE") &&
        identical(j8$providers$PAPER_SPINE_PROVIDER$name, "paper-spine"))

## ================= O9 对抗性反例（RC hardening）=================
## O9a statistics_contract.status=FAIL 绝不成为 Stage PASS
proj9a <- file.path(tmp_base, "proj_stat_status_fail")
dir.create(proj9a, recursive = TRUE, showWarnings = FALSE)
write_valid_artifacts(proj9a)
sl <- readLines(file.path(proj9a, "statistics_contract.yaml"), warn = FALSE)
sl[grepl("^status:", sl)] <- "status: FAIL"
writeLines(sl, file.path(proj9a, "statistics_contract.yaml"))
r9a <- run_wf(proj9a, skills_root = empty_root)
check("O9a statistics_contract.status=FAIL → SEMANTIC_FAIL, exit 2",
      r9a$rc == 2L && !is.null(r9a$json) &&
        identical(r9a$json$stages$STATISTICS, "SEMANTIC_FAIL") &&
        identical(r9a$json$FINAL_FIGURE_READY, FALSE),
      sprintf("exit=%d stage=%s", r9a$rc,
              if (is.null(r9a$json)) "?" else as.character(r9a$json$stages$STATISTICS)))

## O9a' REVIEW_REQUIRED 同样阻断（单元级）
stats_rr <- file.path(tmp_base, "stats_review_required.yaml")
writeLines(c("biological_unit: patient", "statistical_unit: patient",
             "group_definition: g", "paired: false", "test: t",
             "descriptive_vs_inferential: descriptive",
             "status: REVIEW_REQUIRED"), stats_rr)
v9ar <- validate_artifact(stats_rr, "statistics_contract")
check("O9a' status=REVIEW_REQUIRED → SEMANTIC_FAIL",
      v9ar$status == "SEMANTIC_FAIL" && grepl("never become", v9ar$detail))

## O9b figure_mission.status=DRAFT 不得到达最终门控
proj9b <- file.path(tmp_base, "proj_mission_draft")
dir.create(proj9b, recursive = TRUE, showWarnings = FALSE)
write_valid_artifacts(proj9b)
ml <- readLines(file.path(proj9b, "figure_mission.yaml"), warn = FALSE)
ml[grepl("^status:", ml)] <- "status: DRAFT"
writeLines(ml, file.path(proj9b, "figure_mission.yaml"))
r9b <- run_wf(proj9b, skills_root = empty_root)
check("O9b figure_mission.status=DRAFT → SEMANTIC_FAIL, exit 2",
      r9b$rc == 2L && !is.null(r9b$json) &&
        identical(r9b$json$stages$PAPER_SPINE_LITE, "SEMANTIC_FAIL") &&
        identical(r9b$json$FINAL_FIGURE_READY, FALSE),
      sprintf("exit=%d stage=%s", r9b$rc,
              if (is.null(r9b$json)) "?" else as.character(r9b$json$stages$PAPER_SPINE_LITE)))

## O9c paper_spine_final.md 只有 "hello" → 非空文本不构成 PASS
spine9c <- file.path(tmp_base, "hello_spine.md")
writeLines("hello", spine9c)
v9c <- validate_artifact(spine9c, "paper_spine_final")
check("O9c paper_spine_final.md='hello' → PARSE_FAIL (no frontmatter)",
      v9c$status == "PARSE_FAIL", v9c$detail)

## O9d 对抗性转义审计 JSON（Windows 路径/换行/Unicode/控制字符）+ 真实绑定
if (have_jsonlite) {
  bind_dir <- file.path(tmp_base, "o9d_inputs")
  dir.create(bind_dir, recursive = TRUE, showWarnings = FALSE)
  writeBin(charToRaw("abc"), file.path(bind_dir, "figure.png"))
  hash9d <- sha256_file(file.path(bind_dir, "figure.png"))
  body9 <- list(contract_version = "R6.1",
                figure_integrity = list(status = "PASS"),
                publication_package = list(status = "PASS"),
                publication_ready = TRUE,
                audited_artifacts = list("figure.png" = list(sha256 = hash9d, bytes = 3)),
                repair_routes = list(NEXT_ACTION = "NONE"),
                findings = list(list(
                  issue = paste0("C", ":\\Users\\YHN\\Figure\\panel.png\n",
                                 "line2\t中文 “quoted” ", intToUtf8(1)))))
  adv_json <- file.path(tmp_base, "adv_audit.json")
  writeLines(as.character(jsonlite::toJSON(body9, auto_unbox = TRUE)), adv_json)
  v9d <- validate_artifact(adv_json, "figure_audit")
  check("O9d adversarial-escaped audit JSON → ACCEPT", v9d$status == "ACCEPT",
        v9d$detail)
  check("O9d' binding verifies against real files",
        is.null(verify_audit_binding(v9d$data, bind_dir)))
  con9 <- file(file.path(bind_dir, "figure.png"), open = "ab")
  writeBin(as.raw(0x00), con9); close(con9)
  stale9 <- verify_audit_binding(v9d$data, bind_dir)
  check("O9d'' corrupted input → sha256 mismatch detected",
        !is.null(stale9) && grepl("mismatch", stale9), stale9 %||% "")
} else {
  for (nm in c("O9d", "O9d'", "O9d''")) check(nm, FALSE, "jsonlite unavailable")
}

## O9e spine alignment=REVISED → 阻断
spine9e <- file.path(tmp_base, "spine_revised.md")
writeLines(c("---", "figure_id: X", "central_claim: c", "alignment: REVISED",
             "---", "body text"), spine9e)
v9e <- validate_artifact(spine9e, "paper_spine_final")
check("O9e alignment=REVISED → SEMANTIC_FAIL",
      v9e$status == "SEMANTIC_FAIL" && grepl("CONFIRMED", v9e$detail))

## O9f spine frontmatter 有效但正文为空 → 阻断
spine9f <- file.path(tmp_base, "spine_empty_body.md")
writeLines(c("---", "figure_id: X", "central_claim: c", "alignment: CONFIRMED",
             "---", "   "), spine9f)
v9f <- validate_artifact(spine9f, "paper_spine_final")
check("O9f empty spine body → SEMANTIC_FAIL",
      v9f$status == "SEMANTIC_FAIL" && grepl("body", v9f$detail))

## O9g spine frontmatter 缺 alignment → SCHEMA_FAIL
spine9g <- file.path(tmp_base, "spine_no_alignment.md")
writeLines(c("---", "figure_id: X", "central_claim: c", "---", "body"), spine9g)
v9g <- validate_artifact(spine9g, "paper_spine_final")
check("O9g missing alignment field → SCHEMA_FAIL",
      v9g$status == "SCHEMA_FAIL" && grepl("alignment", v9g$detail))

## O9h E2E: PASS 审计后篡改输入 → AUDIT_STALE; --invoke-audit 强制重审恢复
if (e2e_possible) {
  proj9h <- file.path(tmp_base, "proj_stale")
  dir.create(file.path(proj9h, "figure"), recursive = TRUE, showWarnings = FALSE)
  invisible(file.copy(list.files(ready_case, full.names = TRUE),
                      file.path(proj9h, "figure"), recursive = TRUE))
  unlink(file.path(proj9h, "figure", "figure_audit.json"))
  write_valid_artifacts(proj9h)
  r91 <- run_wf(proj9h, extra_args = "--invoke-audit",
                skills_root = dirname(audit_root))
  check("O9h-1 fresh forced audit → exit 0", r91$rc == 0L, sprintf("exit=%d", r91$rc))
  check("O9h-2 audit_binding=VERIFIED",
        !is.null(r91$json) && identical(r91$json$audit_binding, "VERIFIED"),
        if (is.null(r91$json)) "no json" else as.character(r91$json$audit_binding))
  figp <- file.path(proj9h, "figure", "figure.png")
  con9h <- file(figp, open = "ab")
  writeBin(as.raw(c(0xde, 0xad, 0xbe, 0xef)), con9h); close(con9h)
  r92 <- run_wf(proj9h, skills_root = dirname(audit_root))
  check("O9h-3 tampered input without re-audit → exit 2 AUDIT_STALE",
        r92$rc == 2L && !is.null(r92$json) &&
          identical(r92$json$stages$FIGURE_AUDIT, "AUDIT_STALE"),
        sprintf("exit=%d stage=%s", r92$rc,
                if (is.null(r92$json)) "?" else as.character(r92$json$stages$FIGURE_AUDIT)))
  check("O9h-4 audit_binding reports STALE reason",
        !is.null(r92$json) && grepl("^STALE", as.character(r92$json$audit_binding)),
        if (is.null(r92$json)) "no json" else as.character(r92$json$audit_binding))
  ra92 <- if (is.null(r92$json)) "" else paste(unlist(r92$json$routing_advice), collapse = " ")
  check("O9h-5 routing advice demands forced re-audit", grepl("AUDIT_STALE", ra92))
  check("O9h-6 FINAL_FIGURE_READY false while stale",
        !is.null(r92$json) && identical(r92$json$FINAL_FIGURE_READY, FALSE))
  r93 <- run_wf(proj9h, extra_args = "--invoke-audit",
                skills_root = dirname(audit_root))
  check("O9h-7 --invoke-audit forces re-audit → PASS again (exit 0)",
        r93$rc == 0L && !is.null(r93$json) &&
          identical(r93$json$stages$FIGURE_AUDIT, "PASS") &&
          identical(r93$json$audit_binding, "VERIFIED"),
        sprintf("exit=%d stage=%s", r93$rc,
                if (is.null(r93$json)) "?" else as.character(r93$json$stages$FIGURE_AUDIT)))

  ## O9i E2E: spine figure_id 与 mission 不一致 → SEMANTIC_FAIL
  proj9i <- file.path(tmp_base, "proj_fid_mismatch")
  dir.create(file.path(proj9i, "figure"), recursive = TRUE, showWarnings = FALSE)
  invisible(file.copy(list.files(ready_case, full.names = TRUE),
                      file.path(proj9i, "figure"), recursive = TRUE))
  unlink(file.path(proj9i, "figure", "figure_audit.json"))
  write_valid_artifacts(proj9i)
  sp <- readLines(file.path(proj9i, "paper_spine_final.md"), warn = FALSE)
  sp[grepl("^figure_id:", sp)] <- "figure_id: WRONG_ID"
  writeLines(sp, file.path(proj9i, "paper_spine_final.md"))
  r94 <- run_wf(proj9i, extra_args = "--invoke-audit",
                skills_root = dirname(audit_root))
  check("O9i spine figure_id mismatch → SEMANTIC_FAIL, exit 2",
        r94$rc == 2L && !is.null(r94$json) &&
          identical(r94$json$stages$PAPER_SPINE_FINAL, "SEMANTIC_FAIL") &&
          identical(r94$json$FINAL_FIGURE_READY, FALSE),
        sprintf("exit=%d stage=%s", r94$rc,
                if (is.null(r94$json)) "?" else as.character(r94$json$stages$PAPER_SPINE_FINAL)))
} else {
  for (nm in c("O9h-1", "O9h-2", "O9h-3", "O9h-4", "O9h-5", "O9h-6", "O9h-7", "O9i")) {
    check(nm, FALSE, "audit skill root / fixtures missing (required for release evidence)")
  }
}

cat(sprintf("\nORCHESTRATOR TESTS: %d/%d PASS\n", pass, pass + fail))
quit(status = if (fail == 0) 0 else 1)

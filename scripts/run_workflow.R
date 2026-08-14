#!/usr/bin/env Rscript
# run_workflow.R — Potato Publication Figure Workflow v0.2.1-alpha (W2 contract)
# 门控多 skill 编排器。消费契约, 不执行统计/画图/审计本身。
#
# 用法:
#   Rscript run_workflow.R <project_dir> [--json] [--invoke-audit]
#                          [--skills-root <dir>]
#
# v0.2.1-alpha 契约要点:
#   1) 工件验证链: FILE EXISTS -> PARSE -> SCHEMA -> SEMANTIC -> ACCEPT。
#      "文件存在"绝不等于 PASS。
#   2) figure_audit.json 只按 R6.1 分层契约消费:
#      figure_integrity.status / publication_package.status / publication_ready /
#      repair_routes.NEXT_ACTION / contract_version / audited_artifacts。
#      legacy 扁平 verdict 拒绝接受; 状态必须在 R6.1 枚举内;
#      audited_artifacts SHA-256 绑定重算不匹配 → AUDIT_STALE（绝不按 PASS）。
#   3) figure_mission.status 状态机: 只有 LOCKED 可达最终门控;
#      statistics_contract.status 必填枚举: 只有 PASS 可成为 Stage PASS;
#      paper_spine_final.md 必须含机器可读 frontmatter 且 alignment=CONFIRMED。
#   4) providers 用显式能力契约解析（provider_contracts.yaml）, 便携发现:
#      --skills-root > $CODEX_HOME/skills > 平台默认; 未命中 → NOT_AVAILABLE, 绝不猜测。
#   5) --invoke-audit 语义: 强制重新审计（忽略已存在的 figure_audit.json）。
#   6) 退出码: 0 = FINAL_FIGURE_READY; 2 = 运行完成但未就绪;
#      3 = 非法输入; 4 = 内部错误。
#   7) 每次运行产出 workflow_state.yaml + final_gate_report.md。

script_dir <- dirname(normalizePath(sub("^--file=", "",
  commandArgs(FALSE)[grepl("^--file=", commandArgs(FALSE))][1])))
source(file.path(script_dir, "lib", "orchestrator_core.R"))
source(file.path(script_dir, "lib", "sha256.R"))

EXIT_OK <- 0L; EXIT_NOT_READY <- 2L; EXIT_INVALID <- 3L; EXIT_INTERNAL <- 4L

args <- commandArgs(trailingOnly = TRUE)
project <- ""; explicit_root <- ""; as_json <- FALSE; invoke_audit <- FALSE
i <- 1
while (i <= length(args)) {
  a <- args[i]
  if (a == "--json") as_json <- TRUE
  else if (a == "--invoke-audit") invoke_audit <- TRUE
  else if (a == "--skills-root") { i <- i + 1; if (i <= length(args)) explicit_root <- args[i] }
  else if (!grepl("^--", a) && !nzchar(project)) project <- a
  i <- i + 1
}
if (!nzchar(project)) project <- "."

## ---- exit 3: 非法输入 ----
if (!dir.exists(project)) {
  cat(sprintf("ERROR: project directory does not exist: %s\n", project), file = stderr())
  quit(status = EXIT_INVALID)
}

run_workflow <- function() {
  project <<- normalizePath(project, mustWork = TRUE)
  skill_root <- dirname(script_dir)
  contract_path <- file.path(skill_root, "provider_contracts.yaml")
  if (!file.exists(contract_path)) {
    cat(sprintf("ERROR: provider_contracts.yaml not found: %s\n", contract_path), file = stderr())
    return(EXIT_INTERNAL)
  }
  contracts <- load_provider_contracts(contract_path)
  roots <- discover_skills_roots(explicit_root)
  prov <- resolve_providers(roots, contracts)
  resolved <- prov$resolved

  provider_label <- function(role) {
    m <- resolved[[role]]
    if (is.null(m)) "NOT_AVAILABLE" else paste0(m$name, "@", m$version)
  }

  ## ---- 工件路径 ----
  mission_path <- file.path(project, "figure_mission.yaml")
  stats_path <- file.path(project, "statistics_contract.yaml")
  fig_dir <- file.path(project, "figure")
  ## 审计目标目录: figure/ 若自带 manifest 则为交付目录, 否则用项目根
  audit_dir <- if (file.exists(file.path(fig_dir, "figure_manifest.tsv"))) fig_dir else project
  audit_json <- file.path(audit_dir, "figure_audit.json")

  ## ---- 验证链 ----
  v_mission <- validate_artifact(mission_path, "figure_mission")
  v_stats <- validate_artifact(stats_path, "statistics_contract")

  stages <- character()
  blocking <- character()
  stage_set <- function(name, status, detail = "") {
    stages[name] <<- status
    if (status %in% c("FAIL", "BLOCKED", "UNAVAILABLE", "SCHEMA_FAIL", "SEMANTIC_FAIL",
                      "PARSE_FAIL", "CONTRACT_MISMATCH", "AUDIT_STALE")) {
      blocking <<- c(blocking, sprintf("%s: %s%s", name, status,
                                       if (nzchar(detail)) paste0(" - ", detail) else ""))
    }
  }

  ## ---- Stage 1: Paper-Spine Lite (figure_mission.yaml) ----
  stage_set("PAPER_SPINE_LITE",
            if (v_mission$status == "ACCEPT") "PASS" else v_mission$status,
            v_mission$detail)
  if (v_mission$status == "FILE_MISSING" && !is.null(resolved$PAPER_SPINE_PROVIDER)) {
    stage_set("PAPER_SPINE_LITE", "INVOCATION_REQUIRED",
              sprintf("load '%s' to generate figure_mission.yaml", resolved$PAPER_SPINE_PROVIDER$name))
  }

  ## ---- Stage 2: Statistics (statistics_contract.yaml) ----
  stage_set("STATISTICS",
            if (v_stats$status == "ACCEPT") "PASS" else v_stats$status,
            v_stats$detail)
  if (v_stats$status == "FILE_MISSING") {
    if (!is.null(resolved$STATISTICS_PROVIDER)) {
      stage_set("STATISTICS", "INVOCATION_REQUIRED",
                sprintf("load '%s' to produce statistics_contract.yaml", resolved$STATISTICS_PROVIDER$name))
    } else {
      stage_set("STATISTICS", "UNAVAILABLE",
                "STATISTICS_PROVIDER unavailable; supply USER_PROVIDED_STATISTICS (statistics_contract.yaml); never fake PASS")
    }
  }

  ## ---- Stage 3: Figure Generation ----
  has_figure <- dir.exists(fig_dir) &&
    file.exists(file.path(fig_dir, "figure_manifest.tsv")) &&
    any(file.exists(file.path(fig_dir, c("figure.png", "figure.pdf", "figure.svg", "figure.tiff"))))
  if (has_figure) {
    stage_set("FIGURE_GENERATION", "GENERATED")
  } else if (!stages["STATISTICS"] %in% c("PASS")) {
    stage_set("FIGURE_GENERATION", "BLOCKED", "statistics gate not passed; no inferential generation")
  } else if (!is.null(resolved$FIGURE_GENERATOR)) {
    stage_set("FIGURE_GENERATION", "INVOCATION_REQUIRED",
              sprintf("load '%s' to generate the figure into %s", resolved$FIGURE_GENERATOR$name, fig_dir))
  } else {
    stage_set("FIGURE_GENERATION", "BLOCKED",
              "no FIGURE_GENERATOR available; supply USER_PROVIDED_FIGURE")
  }

  ## ---- Stage 4: Figure Audit（只消费 R6.1 分层契约）----
  audit_contract <- list(contract_version = NA, figure_integrity = NA,
                         publication_package = NA, publication_ready = NA,
                         NEXT_ACTION = NA)
  audit_binding <- "NOT_APPLICABLE"
  ## --invoke-audit = 强制重审: 绝不复用已存在的 figure_audit.json（防 stale）
  run_audit_now <- invoke_audit && !is.null(resolved$FIGURE_AUDITOR) && has_figure
  if (run_audit_now) {
    aud_script <- file.path(resolved$FIGURE_AUDITOR$path, "scripts", "audit_figure.R")
    if (!file.exists(aud_script)) {
      stage_set("FIGURE_AUDIT", "UNAVAILABLE",
                sprintf("auditor resolved but entrypoint missing: %s", aud_script))
    } else {
      rscript_bin <- file.path(R.home("bin"), "Rscript")
      rc <- suppressWarnings(system2(rscript_bin,
        c("--vanilla", shQuote(aud_script), shQuote(audit_dir),
          "--mode", shQuote("PUBLICATION_READY"), "--json"),
        stdout = FALSE, stderr = FALSE))
      if (!file.exists(audit_json)) {
        stage_set("FIGURE_AUDIT", "FAIL",
                  sprintf("audit invocation exit=%s produced no figure_audit.json", rc))
      }
    }
  }

  if (file.exists(audit_json)) {
    v_audit <- validate_artifact(audit_json, "figure_audit")
    if (v_audit$status == "ACCEPT") {
      aj <- v_audit$data
      audit_contract <- list(
        contract_version = as.character(aj$contract_version),
        figure_integrity = as.character(aj$figure_integrity$status),
        publication_package = as.character(aj$publication_package$status),
        publication_ready = isTRUE(aj$publication_ready) ||
          identical(as.character(aj$publication_ready), "true"),
        NEXT_ACTION = as.character(aj$repair_routes$NEXT_ACTION))
      ## 新鲜度绑定: 审计之后输入被改动/删除 → AUDIT_STALE, 绝不按 PASS 消费
      stale_reason <- verify_audit_binding(aj, audit_dir)
      if (!is.null(stale_reason)) {
        audit_binding <- paste0("STALE: ", stale_reason)
        stage_set("FIGURE_AUDIT", "AUDIT_STALE", stale_reason)
      } else {
        audit_binding <- "VERIFIED"
        if (isTRUE(audit_contract$publication_ready)) {
          stage_set("FIGURE_AUDIT", "PASS",
                    sprintf("R6.1: FI=%s PP=%s ready=TRUE binding=VERIFIED",
                            audit_contract$figure_integrity,
                            audit_contract$publication_package))
        } else {
          fi <- audit_contract$figure_integrity
          st <- if (fi %in% c("FAIL")) "FAIL"
                else if (fi %in% c("REVISE", "WARNING", "PASS_WITH_WARNINGS",
                                   "PASS_WITH_LIMITED_EVIDENCE", "PASS")) "REVISE"
                else "NOT_EVALUABLE"
          stage_set("FIGURE_AUDIT", st,
                    sprintf("R6.1: FI=%s PP=%s ready=FALSE NEXT_ACTION=%s",
                            fi, audit_contract$publication_package, audit_contract$NEXT_ACTION))
        }
      }
    } else {
      ## PARSE_FAIL / SCHEMA_FAIL(legacy 契约/枚举外状态/缺绑定) / SEMANTIC_FAIL —— 绝不按 PASS 处理
      stage_set("FIGURE_AUDIT",
                if (v_audit$status == "SCHEMA_FAIL") "CONTRACT_MISMATCH" else v_audit$status,
                v_audit$detail)
    }
  } else if (!"FIGURE_AUDIT" %in% names(stages)) {
    if (!is.null(resolved$FIGURE_AUDITOR)) {
      stage_set("FIGURE_AUDIT", "INVOCATION_REQUIRED",
                "run: Rscript <potato-figure-audit>/scripts/audit_figure.R <figure_dir> --mode PUBLICATION_READY --json")
    } else {
      stage_set("FIGURE_AUDIT", "UNAVAILABLE",
                "no FIGURE_AUDITOR available; install potato-figure-audit or perform manual review")
    }
  }

  ## ---- Stage 5: Figure Revision routing（按 NEXT_ACTION）----
  routing_advice <- character()
  if (identical(stages[["FIGURE_AUDIT"]], "PASS")) {
    stage_set("FIGURE_REVISION", "NOT_REQUIRED")
  } else {
    na <- audit_contract$NEXT_ACTION
    if (identical(stages[["FIGURE_AUDIT"]], "AUDIT_STALE")) {
      stage_set("FIGURE_REVISION", "REQUIRED",
                "audited inputs changed after the audit was produced; force a re-audit")
      routing_advice <- c(routing_advice,
        "[AUDIT_STALE] audited_artifacts sha256 binding mismatch or artifact missing; re-run with --invoke-audit (forces re-audit)")
    } else if (!is.na(na) && na %in% NEXT_ACTION_VOCAB && na != "NONE") {
      stage_set("FIGURE_REVISION", "REQUIRED", route_advice(na))
      routing_advice <- c(routing_advice, sprintf("[%s] %s", na, route_advice(na)))
    } else if (identical(stages[["FIGURE_AUDIT"]], "CONTRACT_MISMATCH")) {
      stage_set("FIGURE_REVISION", "REQUIRED",
                "re-run potato-figure-audit >= 0.4.3-alpha to emit the R6.1 tiered contract")
      routing_advice <- c(routing_advice,
        "[CONTRACT_MISMATCH] legacy audit JSON rejected; re-audit with potato-figure-audit >= 0.4.3-alpha")
    } else {
      stage_set("FIGURE_REVISION", "REQUIRED",
                "audit not PASS; resolve blocking issues and re-audit")
    }
  }

  ## ---- Stage 6: Paper-Spine Final（机器契约: frontmatter + alignment=CONFIRMED）----
  ## "文件非空"绝不等于 PASS: 必须通过 FILE EXISTS -> PARSE -> SCHEMA -> SEMANTIC。
  spine_final <- file.path(project, "paper_spine_final.md")
  v_spine <- validate_artifact(spine_final, "paper_spine_final")
  if (!identical(stages[["FIGURE_AUDIT"]], "PASS")) {
    stage_set("PAPER_SPINE_FINAL", "NOT_EVALUABLE", "audit gate not passed")
  } else if (v_spine$status == "ACCEPT") {
    spine_fid <- trimws(as.character(v_spine$data$meta$figure_id %||% ""))
    mission_fid <- trimws(as.character(v_mission$data$figure_id %||% ""))
    if (nzchar(mission_fid) && nzchar(spine_fid) && !identical(spine_fid, mission_fid)) {
      stage_set("PAPER_SPINE_FINAL", "SEMANTIC_FAIL",
                sprintf("figure_id mismatch: spine '%s' vs mission '%s'",
                        spine_fid, mission_fid))
    } else {
      stage_set("PAPER_SPINE_FINAL", "PASS",
                "frontmatter contract validated (alignment=CONFIRMED, non-empty body)")
    }
  } else if (v_spine$status == "FILE_MISSING") {
    if (!is.null(resolved$PAPER_SPINE_PROVIDER)) {
      stage_set("PAPER_SPINE_FINAL", "INVOCATION_REQUIRED",
                sprintf("load '%s' to verify claim alignment; write paper_spine_final.md with machine-readable frontmatter",
                        resolved$PAPER_SPINE_PROVIDER$name))
    } else {
      stage_set("PAPER_SPINE_FINAL", "NOT_EVALUABLE",
                "no paper-spine provider; user claim review required; write paper_spine_final.md (frontmatter contract)")
    }
  } else {
    ## PARSE_FAIL / SCHEMA_FAIL / SEMANTIC_FAIL —— 非空文本不构成 PASS
    stage_set("PAPER_SPINE_FINAL", v_spine$status, v_spine$detail)
  }

  ## ---- Stage 7: FINAL GATE (fail-closed + cross-artifact consistency) ----
  ## v0.2.1-alpha: CROSS_ARTIFACT_CONSISTENCY_GATE —— 各 Stage 工件不得各说各话。
  ## 仅当所有前置 Stage PASS 时才执行（否则保持 NOT_EVALUABLE）。
  pre_ok <- identical(stages[["PAPER_SPINE_LITE"]], "PASS") &&
    identical(stages[["STATISTICS"]], "PASS") &&
    identical(stages[["FIGURE_GENERATION"]], "GENERATED") &&
    identical(stages[["FIGURE_AUDIT"]], "PASS") &&
    identical(stages[["PAPER_SPINE_FINAL"]], "PASS")
  cross_result <- NULL
  if (pre_ok) {
    cross_result <- tryCatch(
      check_cross_artifact_consistency(
        mission = v_mission$data %||% list(),
        statistics = v_stats$data %||% list(),
        spine = v_spine$data %||% list()),
      error = function(e) list(status = "FAIL", checks = list(),
                               reason = paste("cross-artifact check error:", conditionMessage(e)),
                               expected = "", observed = ""))
  }
  final_ready <- pre_ok && !is.null(cross_result) && identical(cross_result$status, "PASS")
  stage_set("FINAL_GATE",
            if (final_ready) "PASS"
            else if (!is.null(cross_result) && identical(cross_result$status, "FAIL")) "FAIL"
            else if (length(blocking)) "FAIL"
            else "NOT_EVALUABLE")
  ## cross-artifact 失败原因（精确分类, 不笼统叫 SEMANTIC_FAIL）
  cross_reason <- if (!is.null(cross_result) && identical(cross_result$status, "FAIL")) {
    sprintf("CROSS_ARTIFACT_MISMATCH: %s", cross_result$reason)
  } else "NONE"
  cross_status <- if (is.null(cross_result)) "NOT_EVALUABLE" else cross_result$status
  ## cross-artifact 失败必须进入 blocking（fail-closed 且可路由）
  ## 注意: 这里是 run_workflow 顶层, 用 <- 局部赋值（<<- 会写到全局）
  if (identical(cross_status, "FAIL") && !any(grepl("CROSS_ARTIFACT_MISMATCH", blocking))) {
    blocking <- c(blocking, cross_reason)
  }

  ## ---- workflow_state.yaml（两级 flat YAML）----
  now <- format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
  state_lines <- c(
    sprintf("workflow_version: %s", WORKFLOW_VERSION),
    sprintf("workflow_contract: %s", WORKFLOW_CONTRACT),
    sprintf("generated_at: \"%s\"", now),
    sprintf("project_dir: %s", gsub("\\\\", "/", project)),
    sprintf("audit_dir: %s", gsub("\\\\", "/", audit_dir)),
    sprintf("discovery_roots: \"%s\"",
            if (length(roots)) paste(gsub("\\\\", "/", roots), collapse = ";") else "NONE"),
    sprintf("providers.STATISTICS_PROVIDER: %s", provider_label("STATISTICS_PROVIDER")),
    sprintf("providers.FIGURE_GENERATOR: %s", provider_label("FIGURE_GENERATOR")),
    sprintf("providers.FIGURE_AUDITOR: %s", provider_label("FIGURE_AUDITOR")),
    sprintf("providers.PAPER_SPINE_PROVIDER: %s", provider_label("PAPER_SPINE_PROVIDER")),
    sprintf("validation.figure_mission: %s", v_mission$status),
    sprintf("validation.statistics_contract: %s", v_stats$status),
    sprintf("validation.paper_spine_final: %s", v_spine$status),
    sprintf("stages.PAPER_SPINE_LITE: %s", stages["PAPER_SPINE_LITE"]),
    sprintf("stages.STATISTICS: %s", stages["STATISTICS"]),
    sprintf("stages.FIGURE_GENERATION: %s", stages["FIGURE_GENERATION"]),
    sprintf("stages.FIGURE_AUDIT: %s", stages["FIGURE_AUDIT"]),
    sprintf("stages.FIGURE_REVISION: %s", stages["FIGURE_REVISION"]),
    sprintf("stages.PAPER_SPINE_FINAL: %s", stages["PAPER_SPINE_FINAL"]),
    sprintf("stages.FINAL_GATE: %s", stages["FINAL_GATE"]),
    sprintf("cross_artifact_consistency.status: %s", cross_status),
    sprintf("cross_artifact_consistency.reason: %s", cross_reason),
    if (!is.null(cross_result) && length(cross_result$checks)) {
      vapply(names(cross_result$checks), function(cn) {
        sprintf("cross_artifact_consistency.checks.%s: %s", cn, cross_result$checks[[cn]])
      }, character(1))
    } else character(),
    sprintf("audit.contract_version: %s", audit_contract$contract_version),
    sprintf("audit.figure_integrity: %s", audit_contract$figure_integrity),
    sprintf("audit.publication_package: %s", audit_contract$publication_package),
    sprintf("audit.publication_ready: %s", if (is.na(audit_contract$publication_ready)) "NA"
            else if (isTRUE(audit_contract$publication_ready)) "true" else "false"),
    sprintf("audit.NEXT_ACTION: %s", audit_contract$NEXT_ACTION),
    sprintf("audit.binding: %s", audit_binding),
    sprintf("final.FINAL_FIGURE_READY: %s", if (final_ready) "true" else "false"))
  writeLines(state_lines, file.path(project, "workflow_state.yaml"))

  ## ---- final_gate_report.md ----
  rpt <- c(
    "# Final Figure Gate Report", "",
    sprintf("- workflow: potato-publication-figure-workflow v%s (%s)", WORKFLOW_VERSION, WORKFLOW_CONTRACT),
    sprintf("- generated: %s", now),
    sprintf("- project: %s", gsub("\\\\", "/", project)), "",
    sprintf("## FINAL_FIGURE_READY = %s", if (final_ready) "TRUE" else "FALSE"), "",
    "## Stage statuses", "",
    "| Stage | Status |", "|---|---|")
  for (s in names(stages)) rpt <- c(rpt, sprintf("| %s | %s |", s, stages[[s]]))
  rpt <- c(rpt, "", "## Artifact validation chain", "",
           sprintf("- figure_mission.yaml: %s (%s)", v_mission$status, v_mission$detail),
           sprintf("- statistics_contract.yaml: %s (%s)", v_stats$status, v_stats$detail),
           sprintf("- paper_spine_final.md: %s (%s)", v_spine$status, v_spine$detail), "",
           "## Audit contract (R6.1)", "",
           sprintf("- contract_version: %s", audit_contract$contract_version),
           sprintf("- figure_integrity: %s", audit_contract$figure_integrity),
           sprintf("- publication_package: %s", audit_contract$publication_package),
           sprintf("- publication_ready: %s", audit_contract$publication_ready),
           sprintf("- NEXT_ACTION: %s", audit_contract$NEXT_ACTION),
            sprintf("- freshness binding (audited_artifacts sha256+bytes): %s", audit_binding), "",
           "## Cross-artifact consistency (v0.2.1-alpha)", "",
           sprintf("- status: %s", cross_status),
           if (nzchar(cross_reason) && cross_reason != "NONE") sprintf("- reason: %s", cross_reason) else "",
           if (!is.null(cross_result) && length(cross_result$checks)) {
             c("", "| Check | Status |", "|---|---|",
               vapply(names(cross_result$checks), function(cn) {
                 sprintf("| %s | %s |", cn, cross_result$checks[[cn]])
               }, character(1)))
           } else character(), "")
  if (length(routing_advice)) {
    rpt <- c(rpt, "## Routing advice", "")
    for (ra in routing_advice) rpt <- c(rpt, sprintf("- %s", ra))
    rpt <- c(rpt, "")
  }
  if (length(blocking)) {
    rpt <- c(rpt, "## Blocking issues", "")
    for (b in blocking) rpt <- c(rpt, sprintf("- %s", b))
    rpt <- c(rpt, "")
  }
  writeLines(rpt, file.path(project, "final_gate_report.md"))

  ## ---- 输出 ----
  if (as_json) {
    if (!requireNamespace("jsonlite", quietly = TRUE)) {
      cat("ERROR: jsonlite unavailable for --json output\n", file = stderr())
      return(EXIT_INTERNAL)
    }
    payload <- list(
      workflow_version = WORKFLOW_VERSION,
      workflow_contract = WORKFLOW_CONTRACT,
      FINAL_FIGURE_READY = final_ready,
      providers = lapply(names(resolved), function(r) provider_label(r)) |>
        setNames(names(resolved)),
      discovery_roots = if (length(roots)) roots else list("NONE"),
      validation = list(figure_mission = v_mission$status,
                        statistics_contract = v_stats$status,
                        paper_spine_final = v_spine$status),
      stages = as.list(stages),
      audit_contract = audit_contract,
      audit_binding = audit_binding,
      cross_artifact_consistency = if (!is.null(cross_result)) {
        c(list(status = cross_status,
               reason = if (cross_reason == "NONE") "" else cross_reason),
          list(checks = if (length(cross_result$checks)) cross_result$checks else list()))
      } else list(status = "NOT_EVALUABLE"),
      routing_advice = if (length(routing_advice)) routing_advice else list(),
      blocking_issues = if (length(blocking)) blocking else list())
    cat(as.character(jsonlite::toJSON(payload, auto_unbox = TRUE, pretty = TRUE)), "\n")
  } else {
    cat("=== Workflow State (v0.2.1-alpha) ===\n")
    for (s in names(stages)) cat(sprintf("%-22s %s\n", s, stages[[s]]))
    cat("\n=== Providers ===\n")
    for (r in names(resolved)) cat(sprintf("%-22s %s\n", r, provider_label(r)))
    cat(sprintf("\naudit contract: FI=%s PP=%s ready=%s NEXT_ACTION=%s\n",
                audit_contract$figure_integrity, audit_contract$publication_package,
                audit_contract$publication_ready, audit_contract$NEXT_ACTION))
    cat(sprintf("\ncross_artifact_consistency: %s\n", cross_status))
    if (nzchar(cross_reason) && cross_reason != "NONE") cat(sprintf("  reason: %s\n", cross_reason))
    cat(sprintf("\nFINAL_FIGURE_READY = %s\n", if (final_ready) "TRUE" else "FALSE"))
    for (ra in routing_advice) cat(sprintf("- %s\n", ra))
  }
  if (final_ready) EXIT_OK else EXIT_NOT_READY
}

exit_code <- tryCatch(run_workflow(), error = function(e) {
  cat(sprintf("INTERNAL ERROR: %s\n", conditionMessage(e)), file = stderr())
  EXIT_INTERNAL
})
quit(status = exit_code)

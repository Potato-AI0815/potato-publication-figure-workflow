#!/usr/bin/env Rscript
# orchestrator_core.R — Potato Publication Figure Workflow v0.2.1-alpha
# 核心契约库（被 run_workflow.R / resolve_dependencies.R / 测试复用）:
#   1) validate_artifact(): FILE EXISTS -> PARSE -> SCHEMA -> SEMANTIC -> ACCEPT
#      （"文件存在"绝不等于 PASS）
#   2) provider_contracts + capability discovery（显式能力匹配, 模糊关键词误配被拒绝;
#      发现失败 -> NOT_AVAILABLE, 绝不猜测）
#   3) R6.1 audit contract 消费（figure_integrity.status / publication_package.status /
#      publication_ready / repair_routes.NEXT_ACTION; 拒绝 legacy verdict）
# 本文件必须可独立 source（不依赖 potato-figure-audit 的任何内部实现）。

WORKFLOW_VERSION <- "0.2.1-alpha"
WORKFLOW_CONTRACT <- "W2"

## ---- 发布加固 (v0.2.1-alpha): 严格 audit contract 版本 ----
## 只接受与 producer 完全一致的 contract version; 禁止前缀/模糊匹配。
EXPECTED_AUDIT_CONTRACT_VERSION <- "R6.1"
## 若未来需要显式兼容多个版本, 必须在此列出全部支持值（禁止正则式大范围接受）。
SUPPORTED_AUDIT_CONTRACTS <- c("R6.1")

## R6.1 NEXT_ACTION 词汇表（与 potato-figure-audit >= 0.4.3-alpha 一致）
NEXT_ACTION_VOCAB <- c("COMPLETE_DELIVERY", "REVISE_FIGURE", "RETURN_TO_STATISTICS",
                       "RETURN_TO_CLAIM_EVIDENCE", "FIX_DELIVERY",
                       "HUMAN_REVIEW_REQUIRED", "NONE")

## R6.1 分层状态词汇表（收紧: 枚举外的值一律 SCHEMA_FAIL, 绝不按 PASS 处理）
FI_STATUS_VOCAB <- c("PASS", "PASS_WITH_WARNINGS", "PASS_WITH_LIMITED_EVIDENCE",
                     "REVISE", "FAIL", "NOT_EVALUABLE")
## v0.2.1-alpha: PUBLICATION_PACKAGE 词汇与 producer 对齐（producer 无 REVISE）。
## producer (potato-figure-audit) 实际发射: PASS / INCOMPLETE / FAIL / NOT_EVALUABLE。
PUBLICATION_PACKAGE_ALLOWED <- c("PASS", "INCOMPLETE", "FAIL", "NOT_EVALUABLE")
PP_STATUS_VOCAB <- PUBLICATION_PACKAGE_ALLOWED

## 工件状态枚举（fail-closed: FAIL / REVIEW_REQUIRED / UNAVAILABLE / DRAFT / CHANGED
## 永远不得变成 Stage PASS; 只有 PASS / LOCKED 放行）
STATISTICS_STATUS_VOCAB <- c("PASS", "FAIL", "REVIEW_REQUIRED", "UNAVAILABLE")
MISSION_STATUS_VOCAB <- c("DRAFT", "LOCKED", "CHANGED")
SPINE_ALIGNMENT_VOCAB <- c("CONFIRMED", "REVISED", "REJECTED")

## 伪重复统计单元（与 potato-figure-audit scientific core 对齐）
PSEUDO_UNITS <- c("cell", "cells", "roi", "rois", "field", "fields", "view",
                  "views", "image", "images", "section", "sections")

## ---------- 最小 flat-YAML 读取（两级: key: value / 父键 + 缩进子键）----------
read_flat_yaml <- function(path) {
  lines <- readLines(path, warn = FALSE, encoding = "UTF-8")
  out <- list()
  parent <- NULL
  for (ln in lines) {
    if (!nzchar(trimws(ln))) next
    if (grepl("^\\s*#", ln)) next
    indented <- grepl("^[ \t]+", ln)
    tl <- trimws(ln)
    m <- regexec("^([A-Za-z0-9_.-]+):\\s*(.*)$", tl)
    parts <- regmatches(tl, m)[[1]]
    if (length(parts) < 3) next
    key <- parts[2]
    value <- trimws(parts[3])
    value <- gsub('^"(.*)"$', "\\1", value)
    value <- gsub("^'(.*)'$", "\\1", value)
    if (indented && !is.null(parent)) {
      if (is.null(out[[parent]])) out[[parent]] <- list()
      out[[parent]][[key]] <- value
    } else if (!nzchar(value)) {
      parent <- key
    } else {
      out[[key]] <- value
      parent <- NULL
    }
  }
  out
}

is_blank <- function(x) is.null(x) || !nzchar(trimws(as.character(x))) ||
  toupper(trimws(as.character(x))) %in% c("NA", "NULL", "NONE")

## ---------- paper_spine_final.md 机器契约 ----------
## 结构: YAML frontmatter（--- ... ---）+ 正文。只有非空文本不构成 PASS ——
## frontmatter 必须携带 figure_id / central_claim / alignment（alignment 必须
## CONFIRMED）, 正文必须非空。
parse_spine_final <- function(path) {
  lines <- readLines(path, warn = FALSE, encoding = "UTF-8")
  if (!length(lines) || trimws(lines[1]) != "---") {
    stop("missing YAML frontmatter: first line must be '---'")
  }
  rest <- lines[-1]
  close_rel <- which(trimws(rest) == "---")[1]
  if (is.na(close_rel)) stop("unterminated YAML frontmatter (no closing '---')")
  fm_lines <- if (close_rel > 1) rest[1:(close_rel - 1)] else character()
  body_lines <- if (close_rel < length(rest)) rest[(close_rel + 1):length(rest)] else character()
  tf <- tempfile(fileext = ".yaml")
  on.exit(unlink(tf), add = TRUE)
  writeLines(fm_lines, tf)
  meta <- read_flat_yaml(tf)
  list(meta = meta, body = paste(body_lines, collapse = "\n"))
}

## ---------- 验证链: FILE EXISTS -> PARSE -> SCHEMA -> SEMANTIC -> ACCEPT ----------
## 返回 list(status, detail, data)。status 词汇:
##   ACCEPT | FILE_MISSING | PARSE_FAIL | SCHEMA_FAIL | SEMANTIC_FAIL
validate_artifact <- function(path, kind) {
  ## 1) FILE EXISTS
  if (!file.exists(path)) {
    return(list(status = "FILE_MISSING",
                detail = sprintf("%s not found: %s", kind, path), data = NULL))
  }
  ## 2) PARSE
  data <- NULL
  if (kind == "figure_audit") {
    if (!requireNamespace("jsonlite", quietly = TRUE)) {
      return(list(status = "PARSE_FAIL",
                  detail = "jsonlite unavailable; cannot parse figure_audit.json", data = NULL))
    }
    data <- tryCatch(jsonlite::fromJSON(path, simplifyVector = FALSE),
                     error = function(e) e)
    if (inherits(data, "error")) {
      return(list(status = "PARSE_FAIL",
                  detail = sprintf("figure_audit.json is not valid JSON: %s",
                                   conditionMessage(data)), data = NULL))
    }
  } else if (kind == "paper_spine_final") {
    data <- tryCatch(parse_spine_final(path), error = function(e) e)
    if (inherits(data, "error")) {
      return(list(status = "PARSE_FAIL",
                  detail = sprintf("paper_spine_final.md is not machine-readable: %s",
                                   conditionMessage(data)), data = NULL))
    }
  } else {
    data <- tryCatch(read_flat_yaml(path), error = function(e) e)
    if (inherits(data, "error") || !is.list(data) || !length(data)) {
      return(list(status = "PARSE_FAIL",
                  detail = sprintf("%s could not be parsed as YAML", kind), data = NULL))
    }
  }
  ## 3) SCHEMA
  schema <- schema_check(data, kind)
  if (!is.null(schema)) return(list(status = "SCHEMA_FAIL", detail = schema, data = data))
  ## 4) SEMANTIC
  semantic <- semantic_check(data, kind)
  if (!is.null(semantic)) return(list(status = "SEMANTIC_FAIL", detail = semantic, data = data))
  ## 5) ACCEPT
  list(status = "ACCEPT", detail = sprintf("%s validated (PARSE+SCHEMA+SEMANTIC)", kind),
       data = data)
}

schema_check <- function(data, kind) {
  required <- switch(kind,
    figure_mission = c("figure_id", "central_claim", "evidence_role",
                       "biological_unit", "statistical_unit", "primary_contrast",
                       "status"),
    statistics_contract = c("biological_unit", "statistical_unit", "group_definition",
                            "paired", "test", "descriptive_vs_inferential",
                            "status"),
    figure_audit = character(),
    character())
  if (kind == "figure_mission") {
    missing <- required[vapply(required, function(k) is_blank(data[[k]]), logical(1))]
    if (length(missing)) {
      return(sprintf("missing required field(s): %s", paste(missing, collapse = ", ")))
    }
    if (!as.character(data$status) %in% MISSION_STATUS_VOCAB) {
      return(sprintf("figure_mission.status outside vocabulary %s: '%s'",
                     paste(MISSION_STATUS_VOCAB, collapse = "|"), data$status))
    }
    return(NULL)
  }
  if (kind == "statistics_contract") {
    missing <- required[vapply(required, function(k) is_blank(data[[k]]), logical(1))]
    if (length(missing)) {
      return(sprintf("missing required field(s): %s", paste(missing, collapse = ", ")))
    }
    if (!as.character(data$status) %in% STATISTICS_STATUS_VOCAB) {
      return(sprintf("statistics_contract.status outside vocabulary %s: '%s'",
                     paste(STATISTICS_STATUS_VOCAB, collapse = "|"), data$status))
    }
    return(NULL)
  }
  if (kind == "paper_spine_final") {
    meta <- data$meta
    required_spine <- c("figure_id", "central_claim", "alignment")
    missing <- required_spine[vapply(required_spine,
                                     function(k) is_blank(meta[[k]]), logical(1))]
    if (length(missing)) {
      return(sprintf("paper_spine_final.md frontmatter missing field(s): %s",
                     paste(missing, collapse = ", ")))
    }
    if (!as.character(meta$alignment) %in% SPINE_ALIGNMENT_VOCAB) {
      return(sprintf("paper_spine_final.md alignment outside vocabulary %s: '%s'",
                     paste(SPINE_ALIGNMENT_VOCAB, collapse = "|"), meta$alignment))
    }
    return(NULL)
  }
  if (kind == "figure_audit") {
    ## R6.1 分层契约必备字段; legacy 扁平 verdict 契约被拒绝
    has_contract_version <- !is_blank(data$contract_version)
    fi <- data$figure_integrity
    pp <- data$publication_package
    fi_ok <- is.list(fi) && !is_blank(fi$status)
    pp_ok <- is.list(pp) && !is_blank(pp$status)
    ready_ok <- is.logical(data$publication_ready) ||
      is.character(data$publication_ready) && data$publication_ready %in% c("true", "false")
    na <- data$repair_routes$NEXT_ACTION
    if (!has_contract_version) {
      return(paste0("legacy audit contract detected (no contract_version; ",
                    if (!is.null(data$verdict)) "flat 'verdict' field present; " else "",
                    "rerun potato-figure-audit >= 0.4.3-alpha to emit the R6.1 tiered contract"))
    }
    ## v0.2.1-alpha: 严格 exact-match（禁止 grepl("^R6") 前缀式接受）
    cv <- as.character(data$contract_version)
    if (!identical(cv, EXPECTED_AUDIT_CONTRACT_VERSION)) {
      return(sprintf("unsupported audit contract_version: %s (expected exactly %s)",
                     cv, EXPECTED_AUDIT_CONTRACT_VERSION))
    }
    if (!fi_ok) return("figure_integrity.status missing (R6.1 tiered contract required)")
    if (!pp_ok) return("publication_package.status missing (R6.1 tiered contract required)")
    if (!as.character(fi$status) %in% FI_STATUS_VOCAB) {
      return(sprintf("figure_integrity.status outside R6.1 vocabulary %s: '%s'",
                     paste(FI_STATUS_VOCAB, collapse = "|"), fi$status))
    }
    if (!as.character(pp$status) %in% PP_STATUS_VOCAB) {
      return(sprintf("publication_package.status outside R6.1 vocabulary %s: '%s'",
                     paste(PP_STATUS_VOCAB, collapse = "|"), pp$status))
    }
    if (!ready_ok) return("publication_ready boolean missing")
    if (is.null(na) || !as.character(na) %in% NEXT_ACTION_VOCAB) {
      return(sprintf("repair_routes.NEXT_ACTION missing or outside vocabulary: %s",
                     if (is.null(na)) "<missing>" else as.character(na)))
    }
    ## v0.4.3-alpha 新鲜度绑定: 无 audited_artifacts 的审计 JSON 不可验证新鲜度 → 拒绝
    aa <- data$audited_artifacts
    if (is.null(aa) || !is.list(aa) || !length(aa)) {
      return(paste0("audited_artifacts missing or empty (freshness binding required; ",
                    "rerun potato-figure-audit >= 0.4.3-alpha with --json)"))
    }
    bad_aa <- names(aa)[vapply(aa, function(e) {
      is.null(e$sha256) || !nzchar(trimws(as.character(e$sha256)))
    }, logical(1))]
    if (length(bad_aa)) {
      return(sprintf("audited_artifacts entries without sha256: %s",
                     paste(bad_aa, collapse = ", ")))
    }
    ## v0.2.1-alpha: bytes 为 audited artifact 元数据必备字段（schema 层强制）
    bad_bytes <- names(aa)[vapply(aa, function(e) {
      is.null(e$bytes) || is.na(suppressWarnings(as.numeric(e$bytes)))
    }, logical(1))]
    if (length(bad_bytes)) {
      return(sprintf("audited_artifacts entries without numeric bytes: %s",
                     paste(bad_bytes, collapse = ", ")))
    }
    return(NULL)
  }
  missing <- required[vapply(required, function(k) is_blank(data[[k]]), logical(1))]
  if (length(missing)) {
    return(sprintf("missing required field(s): %s", paste(missing, collapse = ", ")))
  }
  NULL
}

semantic_check <- function(data, kind) {
  if (kind == "figure_mission") {
    ## 状态机: 只有 LOCKED mission 才能进入最终门控; DRAFT/CHANGED 一律阻断
    ms <- as.character(data$status)
    if (!identical(ms, "LOCKED")) {
      return(sprintf("figure_mission.status is %s; only LOCKED missions may reach the final gate (DRAFT/CHANGED must be re-locked)",
                     ms))
    }
    if (!nzchar(trimws(as.character(data$central_claim)))) {
      return("central_claim is empty")
    }
    if (tolower(trimws(as.character(data$statistical_unit))) %in% PSEUDO_UNITS) {
      return(sprintf("statistical_unit '%s' is a pseudoreplication-prone unit; declare the independent biological unit",
                     data$statistical_unit))
    }
    pd <- tolower(trimws(as.character(data$paired_design %||% "")))
    if (nzchar(pd) && !pd %in% c("true", "false")) {
      return(sprintf("paired_design must be true/false, got '%s'", data$paired_design))
    }
    return(NULL)
  }
  if (kind == "statistics_contract") {
    ## fail-closed: status 为必填枚举, 且只有 PASS 才能成为 Stage PASS
    ss <- as.character(data$status)
    if (!identical(ss, "PASS")) {
      return(sprintf("statistics_contract.status is %s; FAIL/REVIEW_REQUIRED/UNAVAILABLE must never become a Stage PASS",
                     ss))
    }
    unit <- tolower(trimws(as.character(data$statistical_unit)))
    if (unit %in% PSEUDO_UNITS) {
      return(sprintf("statistical_unit '%s' = pseudoreplication; use the independent biological unit",
                     data$statistical_unit))
    }
    paired <- tolower(trimws(as.character(data$paired)))
    if (!paired %in% c("true", "false")) {
      return(sprintf("paired must be true/false, got '%s'", data$paired))
    }
    dvi <- tolower(trimws(as.character(data$descriptive_vs_inferential)))
    if (!dvi %in% c("descriptive", "inferential")) {
      return(sprintf("descriptive_vs_inferential must be descriptive|inferential, got '%s'",
                     data$descriptive_vs_inferential))
    }
    if (dvi == "inferential") {
      nbg <- data$n_by_group
      if (is.null(nbg) || !is.list(nbg) || !length(nbg)) {
        return("inferential contract must declare n_by_group with positive n per group")
      }
      bad <- names(nbg)[vapply(nbg, function(v) {
        nv <- suppressWarnings(as.numeric(v)); is.na(nv) || nv < 1
      }, logical(1))]
      if (length(bad)) {
        return(sprintf("n_by_group must be >= 1 for: %s", paste(bad, collapse = ", ")))
      }
    }
    return(NULL)
  }
  if (kind == "paper_spine_final") {
    meta <- data$meta
    align <- toupper(trimws(as.character(meta$alignment)))
    if (!identical(align, "CONFIRMED")) {
      return(sprintf("paper_spine_final alignment is %s; only CONFIRMED claim alignment may pass the final gate",
                     align))
    }
    if (!nzchar(trimws(as.character(data$body)))) {
      return("paper_spine_final.md body is empty; record the claim-alignment review, not just frontmatter")
    }
    return(NULL)
  }
  if (kind == "figure_audit") {
    ready <- isTRUE(data$publication_ready) ||
      identical(as.character(data$publication_ready), "true")
    fi <- as.character(data$figure_integrity$status)
    pp <- as.character(data$publication_package$status)
    na <- as.character(data$repair_routes$NEXT_ACTION)
    ## v0.2.1-alpha: ready invariant 与 producer 完全一致。
    ## PUBLICATION_READY=TRUE 仅当 FI ∈ {PASS, PASS_WITH_WARNINGS} 且 PP=PASS 且 NEXT_ACTION=NONE。
    ## PASS_WITH_LIMITED_EVIDENCE 是合法 FI 状态但绝不对应 ready=TRUE。
    if (ready && !fi %in% c("PASS", "PASS_WITH_WARNINGS")) {
      return(sprintf("inconsistent audit JSON: publication_ready=true but figure_integrity=%s (ready requires PASS or PASS_WITH_WARNINGS; PASS_WITH_LIMITED_EVIDENCE is not ready)",
                     fi))
    }
    if (ready && !identical(pp, "PASS")) {
      return(sprintf("inconsistent audit JSON: publication_ready=true but publication_package=%s", pp))
    }
    if (ready && !identical(na, "NONE")) {
      return(sprintf("inconsistent audit JSON: publication_ready=true but NEXT_ACTION=%s (ready requires NONE)",
                     na))
    }
    return(NULL)
  }
  NULL
}

## ---------- 审计新鲜度绑定校验（AUDIT_STALE 判定）----------
## 重算 audited_artifacts 中每个文件的 SHA-256 + 字节数; 缺失/不匹配 → 返回原因（stale）。
## v0.2.1-alpha: bytes 也必须一致; 两者都不匹配时优先报告 SHA mismatch。
## 全部一致 → NULL（binding verified）。调用方必须先通过 schema_check
## （audited_artifacts 已是必备字段, 且每个条目含 sha256 + numeric bytes）。
verify_audit_binding <- function(audit_data, audit_dir) {
  aa <- audit_data$audited_artifacts
  if (is.null(aa) || !is.list(aa) || !length(aa)) {
    return("audited_artifacts missing or empty; freshness cannot be verified")
  }
  for (rel in names(aa)) {
    p <- file.path(audit_dir, rel)
    if (!file.exists(p)) {
      return(sprintf("audited artifact no longer exists: %s", rel))
    }
    want_sha <- tolower(trimws(as.character(aa[[rel]]$sha256 %||% "")))
    want_bytes <- suppressWarnings(as.numeric(aa[[rel]]$bytes %||% NA))
    got_sha <- tryCatch(tolower(sha256_file(p)), error = function(e) "")
    got_bytes <- tryCatch(as.numeric(file.info(p)$size), error = function(e) NA_real_)
    sha_mismatch <- !nzchar(want_sha) || !identical(got_sha, want_sha)
    bytes_mismatch <- is.na(want_bytes) || is.na(got_bytes) || !identical(got_bytes, want_bytes)
    if (sha_mismatch && bytes_mismatch) {
      return(sprintf("sha256 and byte-size mismatch for audited artifact: %s", rel))
    }
    if (sha_mismatch) {
      return(sprintf("sha256 mismatch for audited artifact: %s", rel))
    }
    if (bytes_mismatch) {
      return(sprintf("byte-size mismatch for audited artifact: %s", rel))
    }
  }
  NULL
}

`%||%` <- function(a, b) if (is.null(a)) b else a

## ---------- 跨工件一致性（v0.2.1-alpha: CROSS_ARTIFACT_CONSISTENCY_GATE）----------
## 核心目标: 各 Stage 工件不得各说各话。
## 检查域（仅对"两个工件都存在且字段语义明确"的字段建立约束）:
##   figure_id          mission ↔ spine（既有逻辑保留, 这里统一收口）
##   central_claim      mission ↔ spine（精确 canonical 比较, 禁止 LLM fuzzy）
##   statistical_unit   mission ↔ statistics（normalize: trim/lower/collapse）
##   biological_unit    mission ↔ statistics（若两者都存在）
##   paired_design      mission ↔ statistics（canonical boolean）
##   primary_contrast   mission ↔ statistics（仅当存在结构化 group 字段时比较;
##                      自然语言对比 → NOT_MACHINE_CHECKABLE, 不得伪装 PASS）
## 返回 list(status, checks = named list, reason, expected, observed)
## 核心字段（figure_id/central_claim/statistical_unit）适用时 FAIL 即阻断。

normalize_claim <- function(x) {
  x <- trimws(as.character(x %||% ""))
  x <- gsub("[[:space:]]+", " ", x)
  x
}

normalize_unit <- function(x) {
  x <- tolower(trimws(as.character(x %||% "")))
  x <- gsub("[[:space:]]+", " ", x)
  x
}

normalize_bool <- function(x) {
  v <- tolower(trimws(as.character(x %||% "")))
  if (v %in% c("true", "yes", "paired", "1")) return(TRUE)
  if (v %in% c("false", "no", "unpaired", "0")) return(FALSE)
  NA
}

check_cross_artifact_consistency <- function(mission, statistics, spine) {
  checks <- list()
  reasons <- character()
  ## 1) figure_id: mission ↔ spine
  m_fid <- trimws(as.character(mission$figure_id %||% ""))
  s_fid <- trimws(as.character(spine$meta$figure_id %||% ""))
  if (nzchar(m_fid) && nzchar(s_fid)) {
    ok <- identical(m_fid, s_fid)
    checks$figure_id <- if (ok) "PASS" else "FAIL"
    if (!ok) reasons <- c(reasons, sprintf("figure_id mismatch: mission '%s' vs spine '%s'", m_fid, s_fid))
  } else {
    checks$figure_id <- "NOT_APPLICABLE"
  }
  ## 2) central_claim: mission ↔ spine（精确 canonical; alignment=CONFIRMED 不能替代）
  m_claim <- normalize_claim(mission$central_claim)
  s_claim <- normalize_claim(spine$meta$central_claim)
  if (nzchar(m_claim) && nzchar(s_claim)) {
    ok <- identical(m_claim, s_claim)
    checks$central_claim <- if (ok) "PASS" else "FAIL"
    if (!ok) reasons <- c(reasons, "central_claim mismatch")
  } else {
    checks$central_claim <- "NOT_APPLICABLE"
  }
  ## 3) statistical_unit: mission ↔ statistics
  m_unit <- normalize_unit(mission$statistical_unit)
  st_unit <- normalize_unit(statistics$statistical_unit)
  if (nzchar(m_unit) && nzchar(st_unit)) {
    ok <- identical(m_unit, st_unit)
    checks$statistical_unit <- if (ok) "PASS" else "FAIL"
    if (!ok) reasons <- c(reasons,
      sprintf("statistical_unit mismatch: mission '%s' vs statistics '%s'", m_unit, st_unit))
  } else {
    checks$statistical_unit <- "NOT_APPLICABLE"
  }
  ## 4) biological_unit: mission ↔ statistics（两者都存在才比较）
  m_bio <- normalize_unit(mission$biological_unit)
  st_bio <- normalize_unit(statistics$biological_unit)
  if (nzchar(m_bio) && nzchar(st_bio)) {
    ok <- identical(m_bio, st_bio)
    checks$biological_unit <- if (ok) "PASS" else "FAIL"
    if (!ok) reasons <- c(reasons,
      sprintf("biological_unit mismatch: mission '%s' vs statistics '%s'", m_bio, st_bio))
  } else {
    checks$biological_unit <- "NOT_APPLICABLE"
  }
  ## 5) paired_design: mission ↔ statistics（canonical boolean）
  m_pd <- normalize_bool(mission$paired_design)
  st_pd <- normalize_bool(statistics$paired)
  if (!is.na(m_pd) && !is.na(st_pd)) {
    ok <- identical(m_pd, st_pd)
    checks$paired_design <- if (ok) "PASS" else "FAIL"
    if (!ok) reasons <- c(reasons,
      sprintf("paired_design mismatch: mission '%s' vs statistics '%s'",
              as.character(mission$paired_design), as.character(statistics$paired)))
  } else {
    checks$paired_design <- "NOT_APPLICABLE"
  }
  ## 6) primary_contrast: 仅当存在结构化 group_a/group_b 时比较
  m_ga <- normalize_unit(mission$group_a)
  m_gb <- normalize_unit(mission$group_b)
  st_ga <- normalize_unit(statistics$group_a)
  st_gb <- normalize_unit(statistics$group_b)
  if (nzchar(m_ga) && nzchar(st_ga) && nzchar(m_gb) && nzchar(st_gb)) {
    ## group identity 比较（方向无关: A/B 顺序允许互换? 否——主对比方向是科学语义,
    ## 必须一致; 但保守处理: 仅比较 group 身份集合）
    ok <- identical(sort(c(m_ga, m_gb)), sort(c(st_ga, st_gb)))
    checks$primary_contrast <- if (ok) "PASS" else "FAIL"
    if (!ok) reasons <- c(reasons, "primary_contrast group mismatch")
  } else if (nzchar(mission$primary_contrast) && nzchar(statistics$group_definition %||% "")) {
    ## 自然语言对比 → 无法机器验证
    checks$primary_contrast <- "NOT_MACHINE_CHECKABLE"
  } else {
    checks$primary_contrast <- "NOT_APPLICABLE"
  }
  ## 汇总: 核心字段（figure_id/central_claim/statistical_unit）任一 FAIL → 整体 FAIL
  core <- c("figure_id", "central_claim", "statistical_unit")
  core_fail <- any(vapply(core, function(c) identical(checks[[c]], "FAIL"), logical(1)))
  any_fail <- any(vapply(checks, function(s) identical(s, "FAIL"), logical(1)))
  status <- if (core_fail || any_fail) "FAIL" else "PASS"
  list(status = status,
       checks = checks,
       reason = if (length(reasons)) paste(reasons, collapse = "; ") else "",
       expected = "", observed = "")
}

## ---------- provider contracts ----------
## contract 文件为 flat YAML: <ROLE>.preferred_name / .required_tokens / .reject_tokens /
## .entrypoint; token 列表以 ';' 分隔。
load_provider_contracts <- function(contract_path) {
  raw <- read_flat_yaml(contract_path)
  roles <- list()
  for (nm in names(raw)) {
    parts <- strsplit(nm, ".", fixed = TRUE)[[1]]
    if (length(parts) != 2) next
    role <- parts[1]; field <- parts[2]
    if (is.null(roles[[role]])) roles[[role]] <- list()
    roles[[role]][[field]] <- raw[[nm]]
  }
  for (role in names(roles)) {
    rc <- roles[[role]]
    roles[[role]]$required_tokens <- split_tokens(rc$required_tokens)
    roles[[role]]$reject_tokens <- split_tokens(rc$reject_tokens)
  }
  roles
}

split_tokens <- function(x) {
  if (is.null(x) || !nzchar(trimws(x))) return(character())
  toks <- trimws(unlist(strsplit(x, ";", fixed = TRUE)))
  toks[nzchar(toks)]
}

## ---------- skill meta ----------
read_skill_meta <- function(path) {
  skill_md <- file.path(path, "SKILL.md")
  meta <- list(name = basename(path), description = "", version = "unknown", path = path)
  if (file.exists(skill_md)) {
    lines <- readLines(skill_md, warn = FALSE, encoding = "UTF-8")
    in_fm <- FALSE
    fm_end <- 0
    if (length(lines) && trimws(lines[1]) == "---") {
      in_fm <- TRUE
      for (i in 2:length(lines)) {
        if (trimws(lines[i]) == "---") { fm_end <- i; break }
      }
    }
    fm <- if (fm_end > 2) lines[2:(fm_end - 1)] else character()
    desc_lines <- character()
    collecting <- FALSE
    for (ln in fm) {
      if (grepl("^name:", ln)) { meta$name <- trimws(sub("^name:\\s*", "", ln)); collecting <- FALSE }
      else if (grepl("^description:", ln)) {
        collecting <- TRUE
        first <- trimws(sub("^description:\\s*", "", ln))
        if (!grepl("^[>|]", first)) desc_lines <- c(desc_lines, first)
      }
      else if (grepl("^version:", ln)) { meta$version <- trimws(sub("^version:\\s*", "", ln)); collecting <- FALSE }
      else if (collecting && grepl("^\\s{2,}", ln)) desc_lines <- c(desc_lines, trimws(ln))
      else if (!grepl("^\\s", ln)) collecting <- FALSE
    }
    meta$description <- paste(desc_lines, collapse = " ")
  }
  man <- file.path(path, "manifest.yaml")
  if (file.exists(man)) {
    ml <- tryCatch(readLines(man, warn = FALSE, encoding = "UTF-8"), error = function(e) character())
    for (ln in ml) if (grepl("^version:", ln)) meta$version <- trimws(sub("^version:\\s*", "", ln))
  }
  meta
}

## ---------- 显式能力匹配（拒绝模糊关键词误配）----------
## 命中规则:
##   a) 名称与 preferred_name 精确相等 → 直接命中（显式意图优先;
##      真实 potato-figure-audit 的 description 含 "does not generate", 若先跑
##      reject 扫描会自我拒绝, 因此名称命中必须先于 reject 检查）
##   b) 能力路径: 全部 required_tokens 出现在 name+description（小写）,
##      且无任何 reject_token 出现
## suite/kit/bundle/family 聚合类一律拒绝。
match_capability <- function(meta, contract) {
  blob <- tolower(paste(meta$name, meta$description))
  if (grepl("suite|kit|bundle|family", tolower(meta$name))) return(FALSE)
  if (tolower(meta$name) == tolower(contract$preferred_name %||% "")) return(TRUE)
  rej <- contract$reject_tokens
  if (length(rej) && any(vapply(rej, function(t) grepl(tolower(t), blob, fixed = TRUE), logical(1)))) {
    return(FALSE)
  }
  req <- contract$required_tokens
  if (!length(req)) return(FALSE)
  all(vapply(req, function(t) grepl(tolower(t), blob, fixed = TRUE), logical(1)))
}

## ---------- 便携 skill root 发现 ----------
## 顺序: 显式 --skills-root > $CODEX_HOME/skills > 平台默认目录。
## 只报告存在的目录; 全部不存在 → character()（上游必须 NOT_AVAILABLE, 绝不猜测）。
discover_skills_roots <- function(explicit = "") {
  roots <- character()
  if (nzchar(trimws(explicit))) {
    roots <- c(roots, trimws(explicit))
    ## 密封发现（测试/受控部署）: 显式 root + POTATO_SKILLS_NO_FALLBACK=1 → 不追加平台目录
    if (nzchar(Sys.getenv("POTATO_SKILLS_NO_FALLBACK", ""))) {
      return(roots[vapply(roots, dir.exists, logical(1))])
    }
  }
  ch <- Sys.getenv("CODEX_HOME", "")
  if (nzchar(ch)) roots <- c(roots, file.path(ch, "skills"))
  home <- path.expand("~")
  up <- Sys.getenv("USERPROFILE", home)
  roots <- c(roots,
             file.path(up, ".codex", "skills"),
             file.path(home, ".claude", "skills"),
             file.path(home, ".config", "opencode", "skills"))
  roots <- unique(roots)
  roots[vapply(roots, dir.exists, logical(1))]
}

## ---------- provider 解析 ----------
## 返回每个 role: meta list 或 NULL; 另带 discovery_roots 与 per-role 状态。
resolve_providers <- function(roots, contracts) {
  roles <- names(contracts)
  resolved <- setNames(vector("list", length(roles)), roles)
  status <- setNames(rep("NOT_AVAILABLE", length(roles)), roles)
  if (length(roots)) {
    dirs <- unlist(lapply(roots, function(r) list.dirs(r, recursive = FALSE)),
                   use.names = FALSE)
    dirs <- unique(dirs)
    metas <- lapply(dirs, read_skill_meta)
    for (role in roles) {
      for (meta in metas) {
        if (match_capability(meta, contracts[[role]])) {
          resolved[[role]] <- meta
          status[[role]] <- "AVAILABLE"
          break
        }
      }
    }
  }
  list(resolved = resolved, status = status, roots = roots)
}

## ---------- NEXT_ACTION → 阶段路由建议 ----------
route_advice <- function(next_action) {
  switch(as.character(next_action),
    COMPLETE_DELIVERY = "Figure is sound; complete the publication package (exports, delivery metadata, session info, global state) and re-run the audit.",
    REVISE_FIGURE = "Visual/color/panel work required; route to FIGURE_GENERATOR with the visual correction brief, then re-audit.",
    RETURN_TO_STATISTICS = "Scientific/statistical defect; route to STATISTICS provider or user statistical review before any re-render.",
    RETURN_TO_CLAIM_EVIDENCE = "Claim-evidence misalignment; route to PAPER_SPINE to re-align claim/panels, then regenerate.",
    FIX_DELIVERY = "Delivery material declared but wrong (hash/DPI/schema contradiction); fix the declared artifacts, not the figure.",
    HUMAN_REVIEW_REQUIRED = "Multiple distinct repair targets or not evaluable; coordinate human review before further automation.",
    NONE = "No repair routed.",
    sprintf("Unknown NEXT_ACTION '%s'; treat as HUMAN_REVIEW_REQUIRED.", next_action))
}

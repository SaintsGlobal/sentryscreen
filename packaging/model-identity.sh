#!/bin/bash
# Measure or verify a model package without printing its internal paths.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The path is fixed to the runtime repository root. SENTRY_MODEL_FILE is the
# payload basename this manifest binds the artifact to; see its receipt.
# shellcheck disable=SC1090,SC1091
source "$ROOT/packaging/release.env"

usage() {
  cat >&2 <<'EOF'
usage:
  packaging/model-identity.sh measure <model.mlpackage>
  packaging/model-identity.sh write-development <model.mlpackage>
  packaging/model-identity.sh verify <model.mlpackage> <manifest.tsv> [approval-status]
EOF
  exit 64
}

fail() {
  echo "model-identity: $*" >&2
  exit 1
}

sha256_of() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

mode_of() {
  local observed
  observed=$(/usr/bin/stat -f '%p' "$1") || \
    fail "cannot read entry mode remediation=inspect the model package permissions"
  printf '%04o' "$((8#$observed & 4095))"
}

measure_model() {
  local model="$1" index_file="$2"
  local item relative entry_mode entry_size entry_hash
  local total_size=0 file_count=0

  [ -d "$model" ] && [ ! -L "$model" ] || \
    fail "model configured=regular-directory observed=missing-or-unsafe path=$model remediation=SENTRY_MODEL_PATH"
  : > "$index_file"
  while IFS= read -r -d '' item; do
    relative=${item#"$model/"}
    # pkgbuild can encode extended attributes as valid AppleDouble sidecars.
    # They are package metadata, not model identity. The payload audit validates
    # their structure separately and omits them from its logical manifest.
    case "/$relative" in */._*) continue ;; esac
    [ ! -L "$item" ] || \
      fail "model entry configured=regular-file-or-directory observed=symbolic-link remediation=replace model links before packaging"
    entry_mode=$(mode_of "$item")
    if [ -d "$item" ]; then
      printf 'directory\0%s\0%s\0' "$relative" "$entry_mode" >> "$index_file"
    elif [ -f "$item" ]; then
      entry_size=$(/usr/bin/stat -f '%z' "$item")
      entry_hash=$(sha256_of "$item")
      total_size=$((total_size + entry_size))
      file_count=$((file_count + 1))
      printf 'file\0%s\0%s\0%s\0%s\0' \
        "$relative" "$entry_mode" "$entry_size" "$entry_hash" >> "$index_file"
    else
      fail "model entry configured=regular-file-or-directory observed=unsupported remediation=replace special entries before packaging"
    fi
  done < <(/usr/bin/find -P "$model" -mindepth 1 -print0 | LC_ALL=C /usr/bin/sort -z)

  [ "$file_count" -gt 0 ] || \
    fail "model configured=non-empty observed=0-files path=$model remediation=provide the complete model artifact"
  printf 'file_count\t%s\n' "$file_count"
  printf 'total_size\t%s\n' "$total_size"
  printf 'sha256\t%s\n' "$(sha256_of "$index_file")"
}

manifest_value() {
  local manifest="$1" key="$2"
  /usr/bin/awk -F '\t' -v wanted="$key" '
    $1 == wanted { count++; value = $2 }
    END {
      if (count != 1) exit 1
      print value
    }
  ' "$manifest" || fail "manifest field configured=exactly-one observed=missing-or-duplicate name=$key remediation=repair-the-model-manifest"
}

validate_manifest_shape() {
  local manifest="$1"
  [ -f "$manifest" ] && [ ! -L "$manifest" ] || \
    fail "manifest configured=regular-file observed=missing-or-unsafe path=$manifest remediation=SENTRY_MODEL_MANIFEST"
  [ "$(/usr/bin/sed -n '1p' "$manifest")" = '# sentryscreen-model-identity-v1' ] || \
    fail "manifest schema configured=sentryscreen-model-identity-v1 observed=missing-or-other remediation=repair-the-model-manifest"
  /usr/bin/awk -F '\t' '
    NR == 1 { next }
    NF != 2 { bad = "field-width"; exit }
    $1 !~ /^(schema_version|model_id|approval_status|payload_path|file_count|total_size|sha256)$/ {
      bad = "unknown-field:" $1; exit
    }
    seen[$1]++
    END {
      if (bad != "") { print bad > "/dev/stderr"; exit 1 }
      if (NR != 8) { print "field-count:" NR - 1 > "/dev/stderr"; exit 1 }
      for (key in seen) if (seen[key] != 1) {
        print "duplicate-field:" key > "/dev/stderr"; exit 1
      }
    }
  ' "$manifest" || \
    fail "manifest configured=seven-known-unique-fields observed=invalid remediation=repair-the-model-manifest"
}

write_manifest() {
  local model="$1" model_id="$2" approval="$3"
  local work measurements file_count total_size sha256
  work=$(mktemp -d "${TMPDIR:-/tmp}/sentryscreen-model-identity.XXXXXX")
  trap '/bin/rm -rf "$work"' RETURN
  measure_model "$model" "$work/index" > "$work/measurements.tsv"
  measurements="$work/measurements.tsv"
  file_count=$(manifest_value "$measurements" file_count)
  total_size=$(manifest_value "$measurements" total_size)
  sha256=$(manifest_value "$measurements" sha256)
  printf '# sentryscreen-model-identity-v1\n'
  printf 'schema_version\t1\n'
  printf 'model_id\t%s\n' "$model_id"
  printf 'approval_status\t%s\n' "$approval"
  printf 'payload_path\t%s\n' "$SENTRY_MODEL_FILE"
  printf 'file_count\t%s\n' "$file_count"
  printf 'total_size\t%s\n' "$total_size"
  printf 'sha256\t%s\n' "$sha256"
  /bin/rm -rf "$work"
  trap - RETURN
}

command=${1:-}
case "$command" in
  measure)
    [ "$#" -eq 2 ] || usage
    work=$(mktemp -d "${TMPDIR:-/tmp}/sentryscreen-model-measure.XXXXXX")
    trap '/bin/rm -rf "$work"' EXIT
    printf '# sentryscreen-model-measurement-v1\n'
    measure_model "$2" "$work/index"
    ;;
  write-development)
    [ "$#" -eq 2 ] || usage
    write_manifest "$2" development-unapproved development-only
    ;;
  verify)
    [ "$#" -eq 3 ] || [ "$#" -eq 4 ] || usage
    model="$2"
    manifest="$3"
    required_approval=${4:-}
    validate_manifest_shape "$manifest"
    schema_version=$(manifest_value "$manifest" schema_version)
    model_id=$(manifest_value "$manifest" model_id)
    approval=$(manifest_value "$manifest" approval_status)
    payload_path=$(manifest_value "$manifest" payload_path)
    expected_files=$(manifest_value "$manifest" file_count)
    expected_size=$(manifest_value "$manifest" total_size)
    expected_hash=$(manifest_value "$manifest" sha256)
    [ "$schema_version" = 1 ] || \
      fail "manifest field=schema_version configured=1 observed=$schema_version remediation=repair-the-model-manifest"
    [[ "$model_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || \
      fail "manifest field=model_id configured=safe-identifier observed=invalid remediation=repair-the-model-manifest"
    case "$approval" in development-only|owner-approved) ;; *)
      fail "manifest field=approval_status configured=development-only-or-owner-approved observed=$approval remediation=repair-the-model-manifest"
      ;;
    esac
    [ "$payload_path" = "$SENTRY_MODEL_FILE" ] || \
      fail "manifest field=payload_path configured=$SENTRY_MODEL_FILE observed=$payload_path remediation=repair-the-model-manifest"
    [[ "$expected_files" =~ ^[1-9][0-9]*$ ]] || \
      fail "manifest field=file_count configured=positive-integer observed=$expected_files remediation=repair-the-model-manifest"
    [[ "$expected_size" =~ ^[0-9]+$ ]] || \
      fail "manifest field=total_size configured=nonnegative-integer observed=$expected_size remediation=repair-the-model-manifest"
    [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || \
      fail "manifest field=sha256 configured=64-lowercase-hex observed=invalid remediation=repair-the-model-manifest"
    if [ -n "$required_approval" ] && [ "$approval" != "$required_approval" ]; then
      fail "manifest field=approval_status configured=$required_approval observed=$approval remediation=use-the-owner-approved-release-model-manifest"
    fi
    work=$(mktemp -d "${TMPDIR:-/tmp}/sentryscreen-model-verify.XXXXXX")
    trap '/bin/rm -rf "$work"' EXIT
    measure_model "$model" "$work/index" > "$work/actual.tsv"
    actual_files=$(manifest_value "$work/actual.tsv" file_count)
    actual_size=$(manifest_value "$work/actual.tsv" total_size)
    actual_hash=$(manifest_value "$work/actual.tsv" sha256)
    [ "$actual_files" = "$expected_files" ] || \
      fail "identity mismatch name=file_count configured=$expected_files observed=$actual_files remediation=SENTRY_MODEL_MANIFEST"
    [ "$actual_size" = "$expected_size" ] || \
      fail "identity mismatch name=total_size configured=$expected_size observed=$actual_size remediation=SENTRY_MODEL_MANIFEST"
    [ "$actual_hash" = "$expected_hash" ] || \
      fail "identity mismatch name=sha256 configured=$expected_hash observed=$actual_hash remediation=SENTRY_MODEL_MANIFEST"
    echo "model-identity: PASS model_id=$model_id approval_status=$approval file_count=$actual_files total_size=$actual_size sha256=$actual_hash internals=opaque"
    ;;
  *) usage ;;
esac

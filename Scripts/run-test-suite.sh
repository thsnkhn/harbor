#!/usr/bin/env bash

set -uo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:-all}"
derived_data_path="${project_dir}/build/HarborDerivedData"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
results_parent="${project_dir}/build/TestResults"
results_root="${results_parent}/${timestamp}"
fixture_root=""
fixture_pid=""

usage() {
  echo "Usage: Scripts/run-test-suite.sh core|ui|system|live|all|release-smoke [Harbor.app]" >&2
  echo "Set HARBOR_ONLY_TESTING to rerun one XCTest class or method." >&2
}

case "$mode" in
  core|ui|system|live|all|release-smoke) ;;
  *)
    usage
    exit 2
    ;;
esac

cleanup() {
  if [[ -n "$fixture_pid" ]] && kill -0 "$fixture_pid" >/dev/null 2>&1; then
    kill "$fixture_pid" >/dev/null 2>&1 || true
    wait "$fixture_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "$fixture_root" ]] && [[ "$fixture_root" == "${TMPDIR:-/tmp}"/harbor-ui-suite.* ]]; then
    rm -rf "$fixture_root"
  fi
}

trap cleanup EXIT INT TERM

if [[ "$mode" == "release-smoke" ]]; then
  app_path="${2:-${APP_PATH:-${project_dir}/build/export/Harbor.app}}"
  exec "${project_dir}/Scripts/smoke-release.sh" "$app_path"
fi

if [[ "$mode" != "core" ]]; then
  if [[ "${HARBOR_UI_CONFIRM_NO_RUNNING_HARBOR:-NO}" != "YES" ]]; then
    echo "Quit Harbor, then rerun with HARBOR_UI_CONFIRM_NO_RUNNING_HARBOR=YES." >&2
    exit 2
  fi
  if pgrep -x Harbor >/dev/null 2>&1; then
    echo "Harbor is running. Quit it before starting UI automation." >&2
    exit 2
  fi
fi

if [[ "$mode" == "system" || "$mode" == "all" ]]; then
  if [[ "${HARBOR_UI_ALLOW_SYSTEM_INTEGRATIONS:-NO}" != "YES" ]]; then
    echo "System tests change and restore macOS state. Rerun with HARBOR_UI_ALLOW_SYSTEM_INTEGRATIONS=YES." >&2
    exit 2
  fi
  if [[ "${HARBOR_UI_NOTIFICATION_PREAPPROVED:-NO}" != "YES" ]]; then
    echo "Preapprove Harbor notifications, then rerun with HARBOR_UI_NOTIFICATION_PREAPPROVED=YES." >&2
    exit 2
  fi
fi

if [[ "$mode" == "live" || "$mode" == "all" ]]; then
  if [[ "${HARBOR_UI_ALLOW_LIVE_NETWORK:-NO}" != "YES" ]]; then
    echo "Live canaries use public media sites. Rerun with HARBOR_UI_ALLOW_LIVE_NETWORK=YES." >&2
    exit 2
  fi
fi

mkdir -p "$results_root" "$derived_data_path"

start_fixture_server() {
  fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/harbor-ui-suite.XXXXXX")"
  ready_file="${fixture_root}/ready.json"
  fixture_log="${results_root}/fixture-server.jsonl"
  architecture="$(uname -m)"
  ffmpeg_path="${project_dir}/Vendor/MediaRuntime/${architecture}/bin/ffmpeg"

  if [[ ! -x "$ffmpeg_path" ]]; then
    echo "Missing executable fixture generator: $ffmpeg_path" >&2
    exit 1
  fi

  python3 "${project_dir}/Scripts/harbor-fixture-server.py" \
    --ready-file "$ready_file" \
    --log-file "$fixture_log" \
    --work-directory "${fixture_root}/generated" \
    --ffmpeg "$ffmpeg_path" &
  fixture_pid="$!"

  for _ in {1..100}; do
    if [[ -f "$ready_file" ]]; then
      break
    fi
    if ! kill -0 "$fixture_pid" >/dev/null 2>&1; then
      echo "The Harbor fixture server exited before it became ready." >&2
      exit 1
    fi
    sleep 0.1
  done

  if [[ ! -f "$ready_file" ]]; then
    echo "Timed out while starting the Harbor fixture server." >&2
    exit 1
  fi

  export HARBOR_FIXTURE_BASE_URL
  HARBOR_FIXTURE_BASE_URL="$(plutil -extract baseURL raw "$ready_file")"
  export HARBOR_FIXTURE_LOG="$fixture_log"
  export HARBOR_FIXTURE_MEDIA_SHA256
  HARBOR_FIXTURE_MEDIA_SHA256="$(plutil -extract mediaSHA256 raw "$ready_file")"
  echo "Fixture server: $HARBOR_FIXTURE_BASE_URL"
}

run_xcode_group() {
  group="$1"
  plan="$2"
  shift 2

  build_settings=(
    "HARBOR_UI_NOTIFICATION_PREAPPROVED=${HARBOR_UI_NOTIFICATION_PREAPPROVED:-NO}"
  )
  if [[ -n "${HARBOR_FIXTURE_BASE_URL:-}" ]]; then
    build_settings+=(
      "HARBOR_FIXTURE_BASE_URL=${HARBOR_FIXTURE_BASE_URL}"
      "HARBOR_FIXTURE_LOG=${HARBOR_FIXTURE_LOG}"
      "HARBOR_FIXTURE_MEDIA_SHA256=${HARBOR_FIXTURE_MEDIA_SHA256}"
    )
  fi

  result_bundle="${results_root}/${group}.xcresult"
  log_file="${results_root}/${group}.log"
  echo "Running ${group} tests..."

  xcodebuild test \
    -project "${project_dir}/Harbor.xcodeproj" \
    -scheme Harbor \
    -configuration Debug \
    -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath "$derived_data_path" \
    -resultBundlePath "$result_bundle" \
    -testPlan "$plan" \
    "${build_settings[@]}" \
    "$@" 2>&1 | tee "$log_file"
  return "${PIPESTATUS[0]}"
}

needs_fixtures=false
case "$mode" in
  ui|system|live|all) needs_fixtures=true ;;
esac
if [[ "$needs_fixtures" == true ]]; then
  start_fixture_server
fi

status=0
if [[ "$mode" == "core" || "$mode" == "all" ]]; then
  if [[ -n "${HARBOR_ONLY_TESTING:-}" ]]; then
    run_xcode_group Core HarborUIOffline "-only-testing:${HARBOR_ONLY_TESTING}" || status=1
  else
    run_xcode_group Core HarborUIOffline -only-testing:HarborTests || status=1
  fi
fi
if [[ "$mode" == "ui" || "$mode" == "all" ]]; then
  if [[ -n "${HARBOR_ONLY_TESTING:-}" ]]; then
    run_xcode_group OfflineUI HarborUIOffline "-only-testing:${HARBOR_ONLY_TESTING}" || status=1
  else
    run_xcode_group OfflineUI HarborUIOffline -only-testing:HarborUITests || status=1
  fi
fi
if [[ "$mode" == "system" || "$mode" == "all" ]]; then
  run_xcode_group SystemUI HarborUISystem || status=1
fi
if [[ "$mode" == "live" || "$mode" == "all" ]]; then
  run_xcode_group LiveCanary HarborUILiveCanary || status=1
fi

if [[ "$status" -eq 0 ]]; then
  if touch "${results_root}/.passed"; then
    passed_runs=()
    for result_dir in "${results_parent}"/*; do
      if [[ -d "$result_dir" && ! -L "$result_dir" && "${result_dir##*/}" =~ ^[0-9]{8}T[0-9]{6}Z$ && -f "${result_dir}/.passed" ]]; then
        passed_runs+=("$result_dir")
      fi
    done
    remove_count=$((${#passed_runs[@]} - 2))
    for ((index = 0; index < remove_count; index++)); do
      rm -rf -- "${passed_runs[$index]}"
    done
  else
    echo "Could not mark the run as passed; older results were kept." >&2
  fi
else
  touch "${results_root}/.failed"
fi

echo "Results: $results_root"
exit "$status"

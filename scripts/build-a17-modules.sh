#!/usr/bin/env bash
# Reuses the phases of ayaka.sh (sync, gsi-patches, product) but builds only the
# BPF / apex modules that get injected into the HyperOS image.
#   W=$HOME/work GH_TOKEN=... bash scripts/build-a17-modules.sh
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$HERE/ayaka.sh"

MODULES=${MODULES:-com.android.tethering apexd netd}
CRITICAL_RE='^(system/apex|system/bpf|system/netd|packages/modules/Connectivity):'

phase_build_modules() {
  step "build modules: $MODULES ($TARGET-$REL-userdebug)"
  load_env
  local t0=$SECONDS
  # shellcheck disable=SC2086
  m -j"$JOBS" $MODULES || die "module build failed"
  step "build finished in $(( (SECONDS-t0)/60 )) min"
  local out=$ANDROID_PRODUCT_OUT dist=$W/out-modules/system
  rm -rf "$W/out-modules"; mkdir -p "$dist/bin" "$dist/apex"
  for b in apexd netd; do
    [[ -f $out/system/bin/$b ]] && cp -f "$out/system/bin/$b" "$dist/bin/" && ok "bin/$b" || warn WARN "bin/$b not found in $out/system/bin"
  done
  find "$out/system/apex" -maxdepth 1 -name 'com.android.tethering*' -exec cp -f {} "$dist/apex/" \;
  ls -lh "$dist/bin" "$dist/apex"
  [[ -n $(ls "$dist/apex") ]] || die "no tethering apex found in $out/system/apex"
  tar -C "$W/out-modules" -czf "$W/a17-bpf-modules.tar.gz" system
  ok "$W/a17-bpf-modules.tar.gz"
}

main_modules() {
  phase_prereq
  if [[ ! -d $PATCHES/series || " $REDO " == *" fetch "* ]]; then phase_patches_fetch; fi
  done_phase sync    || phase_sync
  done_phase patch   || phase_patch
  if ((${#FAILED[@]})) && printf '%s\n' "${FAILED[@]}" | grep -qE "$CRITICAL_RE"; then
    die "a gsi-patch for apex/bpf/netd/Connectivity failed, see summary above"
  fi
  done_phase product || phase_product
  phase_build_modules
}

[[ ${BASH_SOURCE[0]} == "$0" ]] && main_modules "$@"

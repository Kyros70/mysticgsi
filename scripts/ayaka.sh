#!/usr/bin/env bash
# AyakaUI (Android 17) GSI builder. Resumable, on-screen output only.
#   bash /work/ayaka.sh                  full run (skips finished phases)
#   REDO="patch product" bash ayaka.sh   redo specific phases (fetch sync patch product)
#   JOBS=12 bash ayaka.sh                build jobs
set -uo pipefail

W=${W:-/work}
TREE=$W/ayaka
PATCHES=$W/gsi-patches
STATE=$W/.state-ayaka
JOBS=${JOBS:-$(nproc)}
SYNC_JOBS=${SYNC_JOBS:-8}
REL=${REL:-cp2a}
TARGET=treble_arm64_bvN
MANIFEST=https://github.com/AyakaUI/android_manifest.git
MANIFEST_BRANCH=seventeen
PATCH_REPO=github.com/Kyros70/gsi-patches
PATCH_BRANCH=pixelos
PHH_BRANCH=android-17.0
SKIP_RE=${SKIP_RE-pixelos-device_phh_treble-product-VNDK}
REDO=${REDO:-}

C0=$'\e[0m'; CR=$'\e[31m'; CG=$'\e[32m'; CY=$'\e[33m'; CB=$'\e[36m'
step() { echo; echo "${CB}==[ $* ]==${C0}"; }
info() { echo "${CB}-->${C0} $*"; }
ok()   { echo "  ${CG}OK${C0}      $*"; }
warn() { echo "  ${CY}$1${C0}  ${*:2}"; }
bad()  { echo "  ${CR}FAIL${C0}    $*"; }
die()  { echo "${CR}ERROR:${C0} $*" >&2; exit 1; }

done_phase() { [[ -f $STATE/$1 ]] && [[ " $REDO " != *" $1 "* ]]; }
mark() { mkdir -p "$STATE"; : >"$STATE/$1"; }

# series name -> repo path inside the tree
declare -A MAP=(
  [bionic]=bionic [bootable_recovery]=bootable/recovery [build_make]=build/make
  [build_release]=build/release [device_generic_common]=device/generic/common
  [device_generic_trusty]=device/generic/trusty
  [external_rust_android-crates-io]=external/rust/android-crates-io
  [external_rust_crates_openssl]=external/rust/crates/openssl
  [external_selinux]=external/selinux [frameworks_av]=frameworks/av
  [frameworks_base]=frameworks/base [frameworks_native]=frameworks/native
  [frameworks_opt_net_ims]=frameworks/opt/net/ims
  [frameworks_opt_telephony]=frameworks/opt/telephony
  [hardware_interfaces]=hardware/interfaces [kernel_configs]=kernel/configs
  [packages_apps_Settings]=packages/apps/Settings
  [packages_modules_AppSearch]=packages/modules/AppSearch
  [packages_modules_Bluetooth]=packages/modules/Bluetooth
  [packages_modules_Connectivity]=packages/modules/Connectivity
  [packages_modules_DeviceLock]=packages/modules/DeviceLock
  [packages_modules_DnsResolver]=packages/modules/DnsResolver
  [packages_modules_RemoteKeyProvisioning]=packages/modules/RemoteKeyProvisioning
  [packages_modules_Wifi]=packages/modules/Wifi
  [packages_modules_common]=packages/modules/common
  [packages_providers_DownloadProvider]=packages/providers/DownloadProvider
  [prebuilts_sdk]=prebuilts/sdk [system_apex]=system/apex [system_bpf]=system/bpf
  [system_core]=system/core [system_extras]=system/extras
  [system_fs_fs_mgr]=system/fs/fs_mgr [system_linkerconfig]=system/linkerconfig
  [system_memory_lmkd]=system/memory/lmkd [system_netd]=system/netd
  [system_security]=system/security [system_sepolicy]=system/sepolicy
  [system_vold]=system/vold [test_vts-testcase_hal]=test/vts-testcase/hal
  [trusty_device_desktop]=trusty/device/desktop
  [trusty_vendor_google_aosp]=trusty/vendor/google/aosp
  [vendor_apn]=vendor/apn [vendor_custom]=vendor/custom
)
# copied dirs: tier dir name -> tree path (applied in tier order, no series)
declare -A COPIED=(
  [platform_device_phh_treble]=device/phh/treble
  [treble_app]=treble_app
  [platform_vendor_hardware_overlay]=vendor/hardware_overlay
)
TIERS=(trebledroid personal rom pixelos)

N_OK=0; N_ALREADY=0; N_FUZZ=0; N_FAIL=0; N_SKIP=0
FAILED=()

apply_one() { # <repo dir> <patch file> <label>
  local d=$1 p=$2 n out rc; n=$(basename "$p")
  if [[ -n $SKIP_RE && $n =~ $SKIP_RE ]]; then warn SKIP "$n (SKIP_RE)"; ((N_SKIP++)); return; fi
  if [[ ! -f $p ]]; then warn MISSING "$p"; ((N_SKIP++)); return; fi
  if git -C "$d" apply --check "$p" >/dev/null 2>&1; then
    if git -C "$d" apply --whitespace=nowarn "$p" >/dev/null 2>&1; then ok "$n"; ((N_OK++)); return; fi
  elif git -C "$d" apply -R --check "$p" >/dev/null 2>&1; then
    warn ALREADY "$n"; ((N_ALREADY++)); return
  else
    out=$(patch -d "$d" -p1 -N -F3 --no-backup-if-mismatch --dry-run <"$p" 2>&1); rc=$?
    if ((rc==0)); then
      patch -d "$d" -p1 -N -F3 --no-backup-if-mismatch -s <"$p" >/dev/null 2>&1 && { warn FUZZ "$n"; ((N_FUZZ++)); return; }
    elif grep -q 'Reversed (or previously applied)' <<<"$out"; then
      warn PARTIAL "$n (some hunks already in tree, review by hand)"; ((N_ALREADY++)); FAILED+=("$3: $n [partial]"); return
    fi
  fi
  bad "$n"; ((N_FAIL++)); FAILED+=("$3: $n")
}

apply_series() {
  local s name dir
  for s in "$PATCHES"/series/*.series; do
    name=$(basename "$s" .series); dir=${MAP[$name]:-}
    if [[ -z $dir ]]; then warn SKIP "series $name has no path mapping"; continue; fi
    if [[ ! -d $TREE/$dir ]]; then warn SKIP "$dir not in tree (series $name)"; ((N_SKIP++)); continue; fi
    info "$dir  (series: $name, $(grep -c . "$s") patches)"
    while IFS= read -r line; do
      [[ -z $line ]] && continue
      apply_one "$TREE/$dir" "$PATCHES/$line" "$dir"
    done <"$s"
  done
}

apply_copied() {
  local k dir t p
  for k in "${!COPIED[@]}"; do
    dir=${COPIED[$k]}
    [[ -d $TREE/$dir ]] || { warn SKIP "$dir not in tree"; continue; }
    info "$dir  (tier order: ${TIERS[*]})"
    for t in "${TIERS[@]}"; do
      [[ -d $PATCHES/patches/$t/$k ]] || continue
      for p in "$PATCHES/patches/$t/$k"/*.patch; do
        [[ -f $p ]] && apply_one "$TREE/$dir" "$p" "$dir"
      done
    done
  done
}

ghauth() { printf 'Authorization: Basic %s' "$(printf 'x-access-token:%s' "$GH_TOKEN" | base64 -w0)"; }

phase_prereq() {
  step "prerequisites"
  for c in git repo python3 patch xz; do command -v "$c" >/dev/null || die "missing tool: $c"; done
  git lfs version >/dev/null 2>&1 || warn WARN "git-lfs not found (manifest uses --git-lfs)"
  git config --global user.name  >/dev/null || git config --global user.name  "Kyros70"
  git config --global user.email >/dev/null || git config --global user.email "Kyros70@users.noreply.github.com"
  git config --global color.ui false
  mkdir -p "$W" "$STATE"
  ok "tools present, jobs=$JOBS sync_jobs=$SYNC_JOBS release=$REL"
}

phase_patches_fetch() {
  step "fetch gsi-patches ($PATCH_BRANCH)"
  if [[ -z ${GH_TOKEN:-} ]]; then read -rsp "GitHub token for $PATCH_REPO: " GH_TOKEN; echo; fi
  [[ -n $GH_TOKEN ]] || die "no token"
  if [[ -d $PATCHES/.git ]]; then
    git -C "$PATCHES" -c "http.extraHeader=$(ghauth)" fetch origin "$PATCH_BRANCH" || die "fetch failed"
    git -C "$PATCHES" checkout -q -B "$PATCH_BRANCH" FETCH_HEAD || die "checkout failed"
  else
    git -c "http.extraHeader=$(ghauth)" clone -b "$PATCH_BRANCH" "https://$PATCH_REPO" "$PATCHES" || die "clone failed"
  fi
  unset GH_TOKEN
  ok "$(git -C "$PATCHES" log --oneline -1)"
  ok "$(find "$PATCHES/patches" -name '*.patch' | wc -l) patches, $(ls "$PATCHES/series" | wc -l) series files"
}

phase_sync() {
  step "repo init + sync AyakaUI $MANIFEST_BRANCH"
  mkdir -p "$TREE" && cd "$TREE" || die "cd $TREE"
  if [[ ! -d .repo ]]; then
    repo init -u "$MANIFEST" -b "$MANIFEST_BRANCH" --git-lfs --depth=1 || die "repo init failed"
  fi
  mkdir -p .repo/local_manifests
  cat >.repo/local_manifests/ayaka-gsi.xml <<'MANIFEST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remote name="cawilliamson" fetch="https://github.com/cawilliamson/" />

  <!-- private keys repo needs auth, GSI uses the default test keys -->
  <remove-project name="AyakaUI/android_vendor_lineage_priv_keys" />

  <project path="device/phh/treble" name="android_device_phh_treble" remote="cawilliamson" revision="android-17.0" clone-depth="1" />
  <project path="treble_app" name="android_treble_app" remote="cawilliamson" revision="main" clone-depth="1" />
  <project path="vendor/hardware_overlay" name="android_vendor_hardware_overlay" remote="cawilliamson" revision="main" clone-depth="1" />
  <project path="vendor/interfaces" name="android_vendor_interfaces" remote="cawilliamson" revision="android-17.0" clone-depth="1" />
  <project path="vendor/magisk" name="android_vendor_magisk" remote="cawilliamson" revision="main" clone-depth="1" />
  <project path="vendor/lptools" name="android_vendor_lptools" remote="cawilliamson" revision="main" clone-depth="1" />
  <project path="vendor/vndk-tests" name="android_vendor_vndk-tests" remote="cawilliamson" revision="main" clone-depth="1" />
  <project path="packages/apps/QcRilAm" name="android_packages_apps_QcRilAm" remote="cawilliamson" revision="main" clone-depth="1" />
</manifest>
MANIFEST_EOF
  ok "local manifest written (phh_treble $PHH_BRANCH, treble_app, hardware_overlay, interfaces, QcRilAm...)"
  until repo sync -c --force-sync --no-clone-bundle --no-tags -j"$SYNC_JOBS"; do
    warn RETRY "repo sync failed, retrying in 30s"; sleep 30
  done
  for p in device/custom/sepolicy device/lineage/sepolicy vendor/custom vendor/lineage device/phh/treble treble_app vendor/hardware_overlay; do
    [[ -d $TREE/$p ]] && ok "$p" || die "$p missing after sync"
  done
  mark sync
}

phase_patch() {
  step "applying gsi-patches (synced repos, series order)"
  apply_series
  step "applying gsi-patches (copied dirs, tier order)"
  apply_copied
  step "patch summary"
  echo "  applied=$N_OK already=$N_ALREADY fuzz=$N_FUZZ skipped=$N_SKIP failed=$N_FAIL"
  if ((N_FAIL)); then
    echo "  ${CR}failed patches:${C0}"; printf '    %s\n' "${FAILED[@]}"
  fi
  mark patch
}

# strip RestlessOS bits, inherit AyakaUI instead
ayaka_phh_edit() {
  local phh=$TREE/device/phh/treble
  step "device/phh/treble: remove RestlessOS wallpapers + bootanimation"
  python3 - "$phh/base.mk" <<'PY_EOF'
import re, sys
p = sys.argv[1]
s = open(p).read()
o = s
# prebuilt bootanimation block
s = re.sub(r"# prebuilt bootanimation;.*?bootanimation\.zip:system/media/bootanimation\.zip\n\n?", "", s, flags=re.S)
# restlessos wallpapers copy + wallpaper props
s = re.sub(r"# restlessos default wallpapers.*?RestlessStars-Lock-Dark\.webp\n\n?", "", s, flags=re.S)
s = re.sub(r"PRODUCT_SYSTEM_PROPERTIES \+= \\\n\s+ro\.config\.wallpaper=/system/etc/wallpaper/RestlessStars[^\n]*\\\n\s+ro\.config\.lock_wallpaper=[^\n]*\n\n?", "", s)
# wallpaper picker + RestlessWallpapers
s = re.sub(r"# wallpaper picker and additional on-device wallpaper options[^\n]*\nPRODUCT_PACKAGES \+= \\\n\s+WallpaperPicker2 \\\n\s+RestlessWallpapers\n\n?", "", s)
open(p, "w").write(s)
print("base.mk changed" if s != o else "base.mk already clean")
PY_EOF
  rm -rf "$phh/wallpapers" "$phh/partner-wallpapers" "$phh/bootanimation.zip"
  step "device/phh/treble: drop phh charger images (AyakaUI custom_charger_animation is used)"
  python3 - "$phh/base.mk" <<'PY_EOF'
import re, sys
p = sys.argv[1]; s = open(p).read(); o = s
s = re.sub(r"# Charger image\nPRODUCT_PACKAGES \+= \\\n\s+product_charger_res_images\n\n?", "", s)
open(p, "w").write(s)
print("charger removed from base.mk" if s != o else "charger already removed")
PY_EOF
  rm -f "$phh/charger/Android.mk"
  grep -n 'product_charger_res_images' "$phh/base.mk" && bad "product_charger_res_images still referenced" || ok "no phh charger module left"
  if grep -n -i 'restless\|bootanimation.zip' "$phh/base.mk" "$phh/phh.mk"; then bad "RestlessOS references still in base.mk/phh.mk"; else ok "no RestlessOS wallpaper/bootanimation references left"; fi

  step "device/phh/treble: drop extra VNDK 28/29 (A17 tree has no prebuilts/vndk/v28, v29)"
  sed -i '/^PRODUCT_EXTRA_VNDK_VERSIONS += 28 29$/d' "$phh/base.mk"
  if grep -n 'PRODUCT_EXTRA_VNDK_VERSIONS' "$phh/base.mk"; then bad "PRODUCT_EXTRA_VNDK_VERSIONS still in base.mk"; else ok "no extra VNDK versions left in base.mk"; fi

  step "device/phh/treble: ayaka.mk (AyakaUI flags + vendor/custom inherit)"
  cat >"$phh/ayaka.mk" <<'AYAKA_MK_EOF'
# AyakaUI GSI product
AYAKA_MAINTAINER := Kyros70
WITH_GMS := false
IS_OFFICIAL := false

# lets build/make/core/config.mk pull in device/lineage/sepolicy + device/custom/sepolicy
AYAKA_BUILD := treble
CUSTOM_BUILD := treble

TARGET_DISABLE_EPPE := true
TARGET_SCREEN_WIDTH := 1080

$(call inherit-product, vendor/custom/config/common_full_phone.mk)
-include vendor/lineage/build/core/config.mk
-include vendor/lineage/build/core/apicheck.mk
AYAKA_MK_EOF
  ok "ayaka.mk written"
  step "generate treble products with ayaka.mk"
  (cd "$phh" && bash generate.sh ayaka >/dev/null) || die "generate.sh failed"
  [[ -f $phh/$TARGET.mk ]] && ok "$TARGET.mk generated" || die "$TARGET.mk not generated"
  grep -n 'ayaka' "$phh/$TARGET.mk" | sed 's/^/    /'
}

phase_product() {
  ayaka_phh_edit
  mark product
}

load_env() {
  cd "$TREE" || die "cd $TREE"
  # device/phh/treble/gsi_stubs defines the same AVF modules, keep the stubs and drop the real tree
  if [[ -d $TREE/packages/modules/Virtualization ]]; then
    info "removing packages/modules/Virtualization (gsi_stubs provides these modules)"
    rm -rf "$TREE/packages/modules/Virtualization"
  fi
  export WITH_GMS=false AYAKA_MAINTAINER=Kyros70 IS_OFFICIAL=false
  export LC_ALL=C
  if command -v ccache >/dev/null; then export USE_CCACHE=1 CCACHE_EXEC=$(command -v ccache); fi
  set +u
  # shellcheck disable=SC1091
  source build/envsetup.sh >/dev/null
  lunch "${TARGET}-${REL}-userdebug" || die "lunch failed"
  set -u
}

verify_sepolicy() {
  step "verify AyakaUI sepolicy inheritance"
  local priv
  priv=$(get_build_var SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS 2>/dev/null)
  echo "  SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS:"; tr ' ' '\n' <<<"$priv" | grep -v '^$' | sed 's/^/    /'
  grep -q 'device/custom/sepolicy/private' <<<"$priv" && ok "device/custom/sepolicy/private inherited" \
    || die "device/custom/sepolicy NOT inherited (check AYAKA_BUILD / build/make/core/config.mk)"
  grep -q 'device/lineage/sepolicy' <<<"$priv$(get_build_var BOARD_VENDOR_SEPOLICY_DIRS 2>/dev/null)$(get_build_var SYSTEM_EXT_PUBLIC_SEPOLICY_DIRS 2>/dev/null)" \
    && ok "device/lineage/sepolicy inherited" || warn WARN "device/lineage/sepolicy not seen in sepolicy dirs"
  info "ro.ayaka props"
  get_build_var PRODUCT_PRODUCT_PROPERTIES 2>/dev/null | tr ' ' '\n' | grep -E 'ayaka|custom\.(version|build)' | sed 's/^/    /'
}

phase_build() {
  step "build $TARGET-$REL-userdebug"
  load_env
  verify_sepolicy
  local t0=$SECONDS
  m -j"$JOBS" systemimage || die "build failed"
  step "build finished in $(( (SECONDS-t0)/60 )) min"
  local out=$TREE/out/target/product/tdgsi_arm64_ab
  [[ -f $out/system.img ]] || die "no system.img in $out"
  local name=AyakaUI-17-$(date +%Y%m%d)-GSI-arm64_ab-vanilla.img
  mkdir -p "$W/out-ayaka"
  cp -f "$out/system.img" "$W/out-ayaka/$name"
  info "xz -T0 -9e (takes a while)"
  xz -T0 -9e -kf "$W/out-ayaka/$name"
  ls -lh "$W/out-ayaka/"
  ok "image: $W/out-ayaka/$name.xz"
}

main() {
  phase_prereq
  if [[ ! -d $PATCHES/series || " $REDO " == *" fetch "* ]]; then phase_patches_fetch; fi
  done_phase sync    || phase_sync
  done_phase patch   || phase_patch
  done_phase product || phase_product
  phase_build
}

[[ ${BASH_SOURCE[0]} == "$0" ]] && main "$@"

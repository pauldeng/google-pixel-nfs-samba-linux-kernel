#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=source-lock.env
. "$SCRIPT_DIR/source-lock.env"

workspace="${PWD}/pixel-nas-kernel-workspace"
jobs=$(nproc)
kernel_repo=""
aarch64_repo=""
arm32_repo=""
kernel_repo_explicit=0
aarch64_repo_explicit=0
arm32_repo_explicit=0
clean_build=0
sources_only=0
local_autodetect=1

usage() {
  echo "Usage: $0 [--workspace PATH] [--jobs N] [--kernel-repo PATH] [--aarch64-repo PATH] [--arm32-repo PATH] [--no-local-autodetect] [--clean-build] [--sources-only]"
}
while (($#)); do
  case "$1" in
    --workspace)
      workspace=$2
      shift 2
      ;;
    --jobs)
      jobs=$2
      shift 2
      ;;
    --kernel-repo)
      kernel_repo=$2
      kernel_repo_explicit=1
      shift 2
      ;;
    --aarch64-repo)
      aarch64_repo=$2
      aarch64_repo_explicit=1
      shift 2
      ;;
    --arm32-repo)
      arm32_repo=$2
      arm32_repo_explicit=1
      shift 2
      ;;
    --clean-build)
      clean_build=1
      shift
      ;;
    --sources-only)
      sources_only=1
      shift
      ;;
    --no-local-autodetect)
      local_autodetect=0
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done
[[ $jobs =~ ^[1-9][0-9]*$ ]] || {
  echo "ERROR: --jobs must be a positive integer" >&2
  exit 2
}

workspace=$(realpath -m -- "$workspace")
[[ $workspace != / ]] || {
  echo "ERROR: workspace must not be filesystem root" >&2
  exit 2
}
repos_dir="$workspace/repos"
worktrees_dir="$workspace/worktrees"
out_dir="$workspace/out/common"
artifacts_dir="$workspace/artifacts/common"
mkdir -p "$repos_dir" "$worktrees_dir" "$artifacts_dir"

normalize_url() { printf '%s\n' "${1%.git}" | sed 's#/$##'; }
resolve_ref_commit() {
  local repo=$1 ref=$2 candidate
  for candidate in "refs/remotes/origin/$ref" "refs/tags/$ref" "$ref"; do
    if git -C "$repo" rev-parse --verify "$candidate^{commit}" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}
validate_repo() {
  local repo=$1 expected_url=$2 ref=$3 commit=$4 tree=$5
  [[ -d $repo/.git || -f $repo/.git ]] || {
    echo "ERROR: not a Git repository: $repo" >&2
    exit 1
  }
  local actual_url
  actual_url=$(git -C "$repo" remote get-url origin)
  [[ $(normalize_url "$actual_url") == $(normalize_url "$expected_url") ]] || {
    echo "ERROR: origin mismatch in $repo" >&2
    echo " expected: $expected_url" >&2
    echo " actual:   $actual_url" >&2
    exit 1
  }
  local resolved_commit resolved_tree
  resolved_commit=$(resolve_ref_commit "$repo" "$ref" || true)
  if [[ $resolved_commit != "$commit" ]]; then
    git -C "$repo" fetch --depth=1 --no-tags origin "$ref"
    resolved_commit=$(git -C "$repo" rev-parse "FETCH_HEAD^{commit}")
  fi
  [[ $resolved_commit == "$commit" ]] || {
    echo "ERROR: commit lock mismatch for $repo:$ref" >&2
    exit 1
  }
  resolved_tree=$(git -C "$repo" rev-parse "$commit^{tree}")
  [[ $resolved_tree == "$tree" ]] || {
    echo "ERROR: tree lock mismatch for $repo:$ref" >&2
    exit 1
  }
}
validate_supplied_repo() {
  local repo=$1 expected_url=$2 ref=$3 commit=$4 tree=$5
  [[ -d $repo/.git || -f $repo/.git ]] || {
    echo "ERROR: supplied path is not a Git repository: $repo" >&2
    exit 1
  }
  local actual_url resolved_commit resolved_tree
  actual_url=$(git -C "$repo" remote get-url origin)
  [[ $(normalize_url "$actual_url") == $(normalize_url "$expected_url") ]] || {
    echo "ERROR: supplied repository origin mismatch: $repo" >&2
    exit 1
  }
  resolved_commit=$(resolve_ref_commit "$repo" "$ref" || true)
  [[ $resolved_commit == "$commit" ]] || {
    echo "ERROR: supplied repository lacks the exact locked ref without fetching: $repo:$ref" >&2
    exit 1
  }
  resolved_tree=$(git -C "$repo" rev-parse "$commit^{tree}")
  [[ $resolved_tree == "$tree" ]] || {
    echo "ERROR: supplied repository tree lock mismatch: $repo:$ref" >&2
    exit 1
  }
}
ensure_clone() {
  local supplied=$1 supplied_explicit=$2 option_name=$3 default_path=$4 url=$5 ref=$6 commit=$7 tree=$8
  if [[ -e $default_path ]]; then
    [[ -d $default_path/.git || -f $default_path/.git ]] || {
      echo "ERROR: managed repository path is occupied by a non-repository: $default_path" >&2
      exit 1
    }
    if ((supplied_explicit)); then
      echo "WARNING: $option_name '$supplied' is ignored because the managed repository already exists: $default_path" >&2
      echo "Use a new --workspace to import a different explicit repository." >&2
    fi
  elif [[ -n $supplied ]]; then
    supplied=$(realpath -- "$supplied")
    validate_supplied_repo "$supplied" "$url" "$ref" "$commit" "$tree"
    git clone --no-checkout --local "$supplied" "$default_path" >&2
    git -C "$default_path" remote set-url origin "$url"
  else
    git clone --no-checkout --depth=1 --single-branch --branch "$ref" "$url" "$default_path" >&2
  fi
  realpath -- "$default_path"
}
git_common_dir() {
  local repo=$1 common
  common=$(git -C "$repo" rev-parse --git-common-dir)
  if [[ $common == /* ]]; then
    realpath -m -- "$common"
  else
    realpath -m -- "$repo/$common"
  fi
}
ensure_worktree() {
  local repo=$1 path=$2 commit=$3
  if [[ -e $path ]]; then
    [[ -f $path/.pixel-nas-managed-worktree ]] || {
      echo "ERROR: unmanaged path occupies $path" >&2
      exit 1
    }
    [[ $(git -C "$path" rev-parse HEAD) == "$commit" ]] || {
      echo "ERROR: managed worktree HEAD drift: $path" >&2
      exit 1
    }
    [[ $(git_common_dir "$path") == $(git_common_dir "$repo") ]] || {
      echo "ERROR: managed worktree belongs to a different repository: $path" >&2
      echo "Use a new workspace; existing worktrees are never rebound automatically." >&2
      exit 1
    }
    local dirty
    dirty=$(git -C "$path" status --porcelain --untracked-files=all | grep -v '^?? \.pixel-nas-managed-worktree$' || true)
    [[ -z $dirty ]] || {
      echo "ERROR: managed worktree is dirty; inspect it and use a new workspace rather than resetting automatically: $path" >&2
      git -C "$path" status --short >&2
      exit 1
    }
  else
    git -C "$repo" worktree add --detach "$path" "$commit" >&2
    : >"$path/.pixel-nas-managed-worktree"
  fi
}

if ((local_autodetect)); then
  project_root=$(realpath -m -- "$SCRIPT_DIR/..")
  [[ -n $kernel_repo || ! -d $project_root/android-kernel-msm/.git ]] || kernel_repo="$project_root/android-kernel-msm"
  [[ -n $aarch64_repo || ! -d $project_root/aarch64-linux-android-4.9/.git ]] || aarch64_repo="$project_root/aarch64-linux-android-4.9"
  [[ -n $arm32_repo || ! -d $project_root/arm-linux-androideabi-4.9/.git ]] || arm32_repo="$project_root/arm-linux-androideabi-4.9"
fi

kernel_repo=$(ensure_clone "$kernel_repo" "$kernel_repo_explicit" --kernel-repo "$repos_dir/kernel-msm" "$KERNEL_REPO_URL" "$KERNEL_BRANCH" "$KERNEL_COMMIT" "$KERNEL_TREE")
aarch64_repo=$(ensure_clone "$aarch64_repo" "$aarch64_repo_explicit" --aarch64-repo "$repos_dir/gcc-aarch64" "$AARCH64_REPO_URL" "$AARCH64_TAG" "$AARCH64_COMMIT" "$AARCH64_TREE")
arm32_repo=$(ensure_clone "$arm32_repo" "$arm32_repo_explicit" --arm32-repo "$repos_dir/gcc-arm32" "$ARM32_REPO_URL" "$ARM32_TAG" "$ARM32_COMMIT" "$ARM32_TREE")

validate_repo "$kernel_repo" "$KERNEL_REPO_URL" "$KERNEL_BRANCH" "$KERNEL_COMMIT" "$KERNEL_TREE"
release_commit=$(resolve_ref_commit "$kernel_repo" "$KERNEL_RELEASE_BRANCH" || true)
if [[ $release_commit != "$KERNEL_COMMIT" ]]; then
  git -C "$kernel_repo" fetch --depth=1 --no-tags origin "$KERNEL_RELEASE_BRANCH" >/dev/null
  release_commit=$(git -C "$kernel_repo" rev-parse "FETCH_HEAD^{commit}")
fi
[[ $release_commit == "$KERNEL_COMMIT" ]] || {
  echo "ERROR: release branch does not resolve to the locked kernel commit" >&2
  exit 1
}
validate_repo "$aarch64_repo" "$AARCH64_REPO_URL" "$AARCH64_TAG" "$AARCH64_COMMIT" "$AARCH64_TREE"
validate_repo "$arm32_repo" "$ARM32_REPO_URL" "$ARM32_TAG" "$ARM32_COMMIT" "$ARM32_TREE"

if ((sources_only)); then
  echo "Locked source preparation complete: $repos_dir"
  exit 0
fi

kernel_tree="$worktrees_dir/kernel-msm-${KERNEL_COMMIT:0:12}"
aarch64_tree="$worktrees_dir/gcc-aarch64-${AARCH64_COMMIT:0:12}"
arm32_tree="$worktrees_dir/gcc-arm32-${ARM32_COMMIT:0:12}"
ensure_worktree "$kernel_repo" "$kernel_tree" "$KERNEL_COMMIT"
ensure_worktree "$aarch64_repo" "$aarch64_tree" "$AARCH64_COMMIT"
ensure_worktree "$arm32_repo" "$arm32_tree" "$ARM32_COMMIT"

if ((clean_build)) && [[ -e $out_dir ]]; then
  [[ -d $out_dir && -f $out_dir/.pixel-nas-build-output ]] || {
    echo "ERROR: refusing to clear unmarked output: $out_dir" >&2
    exit 1
  }
  find "$out_dir" -mindepth 1 -maxdepth 1 ! -name .pixel-nas-build-output -exec rm -rf -- {} +
fi
mkdir -p "$out_dir"
: >"$out_dir/.pixel-nas-build-output"

export ARCH=arm64 SUBARCH=arm64
export CROSS_COMPILE="$aarch64_tree/bin/aarch64-linux-android-"
export CROSS_COMPILE_ARM32="$arm32_tree/bin/arm-linux-androideabi-"
export PATH="$aarch64_tree/bin:$arm32_tree/bin:$PATH"
make -C "$kernel_tree" O="$out_dir" "$KERNEL_DEFCONFIG"
cat "$SCRIPT_DIR/nas-kernel.config" >>"$out_dir/.config"
make -C "$kernel_tree" O="$out_dir" olddefconfig

required=(
  'CONFIG_NETWORK_FILESYSTEMS=y' 'CONFIG_NFS_FS=y' 'CONFIG_NFS_V3=y'
  'CONFIG_CIFS=y' 'CONFIG_CIFS_SMB2=y' 'CONFIG_NLS_UTF8=y'
  'CONFIG_LOCALVERSION="-nas1"' '# CONFIG_LOCALVERSION_AUTO is not set'
)
for selection in "${required[@]}"; do
  grep -Fqx "$selection" "$out_dir/.config" || {
    echo "ERROR: resolved config lacks: $selection" >&2
    exit 1
  }
done
if grep -q '^CONFIG_CIFS_SMB311=' "$out_dir/.config"; then
  echo "ERROR: unexpected CONFIG_CIFS_SMB311 symbol appeared in locked tree" >&2
  exit 1
fi

make -C "$kernel_tree" O="$out_dir" -j"$jobs" Image.lz4-dtb
kernel_release=$(make -s -C "$kernel_tree" O="$out_dir" kernelrelease)
[[ $kernel_release == *-nas1* ]] || {
  echo "ERROR: unexpected kernel release: $kernel_release" >&2
  exit 1
}

install -m 0644 "$out_dir/arch/arm64/boot/Image" "$artifacts_dir/Image"
install -m 0644 "$out_dir/arch/arm64/boot/Image.lz4-dtb" "$artifacts_dir/Image.lz4-dtb"
install -m 0644 "$out_dir/.config" "$artifacts_dir/kernel.config"
make -s -C "$kernel_tree" O="$out_dir" savedefconfig
install -m 0644 "$out_dir/defconfig" "$artifacts_dir/defconfig"
install -m 0644 "$SCRIPT_DIR/source-lock.env" "$artifacts_dir/source-lock.env"
{
  echo "lock_version=$LOCK_VERSION"
  echo "kernel_commit=$KERNEL_COMMIT"
  echo "kernel_tree=$KERNEL_TREE"
  echo "kernel_release=$kernel_release"
  echo "supported_devices=marlin,sailfish"
  echo "aarch64_commit=$AARCH64_COMMIT"
  echo "arm32_commit=$ARM32_COMMIT"
  echo "built_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"$artifacts_dir/build-manifest.txt"
(cd "$artifacts_dir" && sha256sum Image Image.lz4-dtb kernel.config defconfig source-lock.env build-manifest.txt >SHA256SUMS)
(cd "$artifacts_dir" && sha256sum -c SHA256SUMS)
echo "Build complete: $artifacts_dir"

#!/bin/bash
# ============================================================
# GitHub mini CLI (curl-based, no jq, token-per-user)
# Requirements: curl, bash 4+, git configured with credential.helper store
# ============================================================
set -euo pipefail

# ----------------------------------------------------------------------
# Functions
# ----------------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage:
  gh.sh -u USER repo list
  gh.sh -u USER repo create REPO
  gh.sh -u USER repo delete REPO
  gh.sh -u USER repo public REPO
  gh.sh -u USER repo private REPO
  gh.sh -u USER repo rename OLD NEW
  gh.sh -u USER repo push REPO COMMENT FILE1 [FILE2 ...]
  gh.sh -u USER repo tree REPO [BRANCH]
  gh.sh -u USER repo diff REPO [BRANCH]
  gh.sh -u USER repo pages REPO [BRANCH] [PATH]
  gh.sh -u USER gist list
  gh.sh -u USER gist public  [-d DESC] [-i GIST_ID] [FILES...]
  gh.sh -u USER gist secret  [-d DESC] [-i GIST_ID] [FILES...]
  gh.sh -u USER gist delete  -i GIST_ID
  gh.sh -u USER noreply
EOF
}

# ----------------------------------------------------------------------
# Core utilities
# ----------------------------------------------------------------------

curl_api() {
  curl -sk \
       -H "Authorization: token $API_TOKEN" \
       -H "Accept: application/vnd.github+json" \
       "$@"
}

json_get() {
  local json="$1"
  local key="$2"
  echo "$json" | tr -d '\n' |
    grep -oE "\"$key\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|true|false|null)" 2>/dev/null |
    sed -E 's/.*"[[:space:]]*:[[:space:]]*(\"([^\"]*)\"|(true|false|null)).*/\2\3/' |
    head -n 1 || true
}

require_user() {
  if [[ -z "$USERNAME" ]]; then
    echo "Error: username is required (-u USER)."
    exit 1
  fi

  CRED_FILE="$HOME/.git/credentials-$USERNAME"
  [[ -f "$CRED_FILE" ]] || touch "$CRED_FILE"

  API_TOKEN=$({ grep -F "https://$USERNAME:" "$CRED_FILE" || true; } \
    | sed -E "s|https://$USERNAME:([^@]+)@.*|\1|" | tail -n 1)

  if [[ -z "$API_TOKEN" ]]; then
    read -sp "Enter your GitHub Personal Access Token (PAT): " API_TOKEN
    echo
    echo "Adding token to $CRED_FILE ..."
    echo "https://$USERNAME:$API_TOKEN@github.com" >> "$CRED_FILE"
  fi
}

require_repo() {
  if [[ -z "$1" ]]; then
    echo "Repository name is required."
    exit 1
  fi
}

# ----------------------------------------------------------------------
# Repo operations
# ----------------------------------------------------------------------

repo_list() {
  require_user
  echo "Listing repositories for $USERNAME..."
  local resp name priv type
  resp=$(curl_api "$API/user/repos?per_page=100")

  # 要素の区切りで改行（空白も改行も許容）
  resp=$(echo "$resp" | tr -d '\n' | sed 's/},[[:space:]]*{/\}\n\{/g')

  while IFS= read -r block; do
    name=$(json_get "$block" "name")
    priv=$(json_get "$block" "private")
    [[ -z "$name" ]] && continue
    if [[ "$priv" == "true" ]]; then
      type="[private]"
    else
      type="[public]"
    fi
    echo "$name  $type"
  done <<< "$resp"
}

repo_create() {
  require_user
  local name="$1"
  require_repo "$name"
  echo "Creating private repository '$name'..."
  local resp url clone_url msg
  resp=$(curl_api -X POST "$API/user/repos" -d "{\"name\": \"$name\", \"private\": true}")
  url=$(json_get "$resp" "html_url")
  clone_url=$(json_get "$resp" "clone_url")
  msg=$(json_get "$resp" "message")
  if [[ -n "$url" ]]; then
    echo "Created private repository: $url"
    echo
    echo "Next steps you may need to do:"
    echo "  git init"
    echo "  git config user.name \"$USERNAME\""
    echo "  git config user.email \"${USERNAME}@users.noreply.github.com\""
    echo "  git add ."
    echo "  git commit -m \"Initial commit\""
    echo "  git remote add origin $clone_url"
    echo "  git branch -M main"
    echo "  git push -u origin main"
  else
    echo "Failed: $msg"
  fi
}

repo_delete() {
  require_user
  local name="$1"
  require_repo "$name"
  read -p "Are you sure you want to delete '$name'? [y/N]: " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    curl_api -X DELETE "$API/repos/$USERNAME/$name" > /dev/null
    echo "Deleted."
  else
    echo "Cancelled."
  fi
}

repo_private() {
  require_user
  local name="$1"
  require_repo "$name"
  echo "Setting '$name' to private..."
  local resp
  resp=$(curl_api -X PATCH "$API/repos/$USERNAME/$name" -d '{"private": true}')
  [[ "$(json_get "$resp" "private")" == "true" ]] && echo "Success." || echo "Failed: $(json_get "$resp" "message")"
}

repo_public() {
  require_user
  local name="$1"
  require_repo "$name"
  echo "Setting '$name' to public..."
  local resp
  resp=$(curl_api -X PATCH "$API/repos/$USERNAME/$name" -d '{"private": false}')
  [[ "$(json_get "$resp" "private")" == "false" ]] && echo "Success." || echo "Failed: $(json_get "$resp" "message")"
}

repo_rename() {
  require_user
  local old="$1" new="$2"
  if [[ -z "$old" || -z "$new" ]]; then
    echo "Usage: gh.sh -u USER repo rename OLD NEW"
    exit 1
  fi
  echo "Renaming '$old' to '$new'..."
  local resp new_url
  resp=$(curl_api -X PATCH "$API/repos/$USERNAME/$old" -d "{\"name\": \"$new\"}")
  new_url=$(json_get "$resp" "html_url")
  [[ -n "$new_url" ]] && echo "Renamed: $new_url" || echo "Failed: $(json_get "$resp" "message")"
}

repo_push() {
  require_user
  local repo="$1"
  local comment="$2"
  shift 2
  local files=("$@")

  echo "Pushing ${#files[@]} file(s) to ${USERNAME}/${repo} ..."

  for file in "${files[@]}"; do
    if [[ ! -f "$file" ]]; then
      echo "Warning: $file not found, skipping."
      continue
    fi

    local content
    content=$(base64 -w0 "$file")
    local path="$file"
    local get_resp sha
    get_resp=$(curl_api -X GET "$API/repos/$USERNAME/$repo/contents/$path" 2>/dev/null || true)
    sha=$(json_get "$get_resp" "sha")

    local data
    if [[ -n "$sha" ]]; then
      data="{\"message\": \"$comment\", \"content\": \"$content\", \"branch\": \"main\", \"sha\": \"$sha\"}"
    else
      data="{\"message\": \"$comment\", \"content\": \"$content\", \"branch\": \"main\"}"
    fi

    local put_resp url msg
    put_resp=$(curl_api -X PUT "$API/repos/$USERNAME/$repo/contents/$path" -d "$data")

    url=$(json_get "$put_resp" "html_url")
    msg=$(json_get "$put_resp" "message")

    if [[ -n "$url" ]]; then
      echo "$file uploaded → $url"
    else
      echo "Failed to push $file: ${msg:-Unknown error}"
    fi
  done
}

repo_tree() {
  require_user
  local name="$1" branch="${2:-main}"
  require_repo "$name"
  echo "Fetching tree for ${USERNAME}/${name} (branch: ${branch})..."
  local resp
  resp=$(curl_api "$API/repos/$USERNAME/$name/git/trees/$branch?recursive=1")
  if ! echo "$resp" | grep -q '"tree"'; then
    echo "Error: $(json_get "$resp" "message")"
    exit 1
  fi
  echo "$resp" | grep -oE '"path": *"[^"]+"' | sed -E 's/.*"path": *"([^"]+)".*/\1/'
}

repo_diff() {
  require_user
  local name="$1" branch="${2:-main}"
  require_repo "$name"
  echo "Comparing local files with remote branch '${branch}'..."
  local remote_files local_files
  remote_files=$(curl_api "$API/repos/$USERNAME/$name/git/trees/$branch?recursive=1" |
    grep -oE '"path": *"[^"]+"' | sed -E 's/.*"path": *"([^"]+)".*/\1/' | sort)
  local_files=$(find . -type f | sed 's|^\./||' | sort)
  echo "Files existing on remote but missing locally:"
  comm -23 <(echo "$remote_files") <(echo "$local_files")
}

repo_pages() {
  require_user
  local name="$1"
  local branch="$2"
  local path="${3:-/}"

  require_repo "$name"

  if [[ -z "$branch" && -z "$path" ]]; then
    echo "Disabling GitHub Pages for $USERNAME/$name ..."
    RESP=$(curl_api -X DELETE "$API/repos/$USERNAME/$name/pages")
    if [[ $? -eq 0 ]]; then
      echo "GitHub Pages disabled."
    else
      echo "Failed to disable Pages: $(json_get "$RESP" "message")"
    fi
    return
  fi

  echo "Enabling GitHub Pages for $USERNAME/$name (branch: ${branch}, path: ${path})..."
  local data
  data=$(printf '{"source": {"branch": "%s", "path": "%s"}}' "$branch" "$path")
  RESP=$(curl_api -X PUT "$API/repos/$USERNAME/$name/pages" -d "$data")

  local url msg
  url=$(json_get "$RESP" "html_url")
  msg=$(json_get "$RESP" "message")

  if [[ -n "$url" ]]; then
    echo "GitHub Pages published: $url"
  else
    echo "Failed: ${msg:-Unknown error}"
  fi
}

# ----------------------------------------------------------------------
# User email (noreply)
# ----------------------------------------------------------------------

noreply() {
  require_user
  echo "Getting noreply email..."
  local resp email
  resp=$(curl_api "$API/user/emails")
  email=$(echo "$resp" | grep -oE '"email": *"[^"]*@users\.noreply\.github\.com"' | sed -E 's/.*"email": *"([^"]*)".*/\1/' | head -n 1)
  if [[ -z "$email" ]]; then
    echo "No noreply email found. Enable 'Keep my email address private' in GitHub settings."
    echo "URL: https://github.com/settings/emails"
    exit 1
  fi
  echo "Setting public email to noreply: $email"
  curl_api -X PATCH "$API/user" -d "{\"email\": \"$email\"}" > /dev/null
  echo "Done."
}



check_git_identity() {
  local expected_user=$1

  local current_name
  local current_email
  current_name=$(git config user.name 2>/dev/null || echo "")
  current_email=$(git config user.email 2>/dev/null || echo "")

  local remote_url
  remote_url=$(git remote get-url origin 2>/dev/null || echo "")

  if [[ "$remote_url" != *"$expected_user"* ]]; then
    echo "Warning: remote URL ($remote_url) does not seem to match expected user ($expected_user)."
  fi

  if [[ "$current_name" != *"$expected_user"* && "$current_email" != *"$expected_user"* ]]; then
    echo "Warning: current git user.name ($current_name) or user.email ($current_email) does not match expected user ($expected_user)."
  fi
}

set_iam() {
  local user=$1
  if [ -z "$user" ]; then
    echo "Usage: gh.sh iam <user>"
    return 1
  fi

  if [ ! -d .git ]; then
    echo "Error: .git directory not found. Run this inside a git repository."
    return 1
  fi

  git config user.name "$user"
  git config user.email "${user}@users.noreply.github.com"
  git config credential.helper "store --file=$HOME/.git/credentials-$user"

  check_git_identity "$user"
  echo "Switched git identity to $user"
}

# ----------------------------------------------------------------------
# Gist operations
# ----------------------------------------------------------------------

gist_upload() {
  require_user
  local visibility_flag="$1" desc="$2" gist_id="$3"
  shift 3
  local files=("$@")

  local visibility=false
  [[ "$visibility_flag" == "public" ]] && visibility=true

  if [[ ${#files[@]} -eq 0 ]]; then
    echo "Collecting tracked files for gist..."
    mapfile -t files < <(git ls-files)
    if [[ ${#files[@]} -eq 0 ]]; then
      echo "No tracked files found."
      exit 1
    fi
  fi

  local files_json="{"
  local first=true
  for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    $first || files_json+=","
    first=false
    local content
    content=$(sed 's/\\/\\\\/g; s/"/\\"/g' "$f" | awk '{printf "%s\\n",$0}')
    files_json+="\"$f\": {\"content\": \"$content\"}"
  done
  files_json+="}"

  local data
  if [[ -n "$desc" ]]; then
    data=$(printf '{"public": %s, "description": "%s", "files": %s}' "$visibility" "$desc" "$files_json")
  else
    data=$(printf '{"public": %s, "files": %s}' "$visibility" "$files_json")
  fi

  local resp url msg
  if [[ -n "$gist_id" ]]; then
    echo "Updating gist $gist_id..."
    resp=$(curl_api -X PATCH "$API/gists/$gist_id" -d "$data")
  else
    echo "Uploading new gist..."
    resp=$(curl_api -X POST "$API/gists" -d "$data")
  fi

  url=$(json_get "$resp" "html_url")
  msg=$(json_get "$resp" "message")

  if [[ -n "$url" ]]; then
    [[ -n "$gist_id" ]] && echo "Updated gist: $url" || echo "Created gist: $url"
  else
    echo "Failed: $msg"
  fi
}

gist_delete() {
  require_user
  local gist_id="$1"
  if [[ -z "$gist_id" ]]; then
    echo "Usage: gh.sh -u USER gist delete -i GIST_ID"
    exit 1
  fi
  echo "Deleting gist $gist_id..."
  read -p "Are you sure you want to delete? [y/N]: " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    curl_api -X DELETE "$API/gists/$gist_id" > /dev/null
    echo "Deleted."
  else
    echo "Cancelled."
  fi
}

gist_list() {
  require_user
  local resp
  resp=$(curl_api "$API/gists")
  echo "https://gist.github.com/$USERNAME/"
  echo "$resp" | tr -d '\n' |
    sed -E 's/}, *"truncated": (false|true) *}/, "truncated": \1}\n/g' |
    sed -E 's/^\[//; s/\]$//' | while IFS= read -r block; do
      local id public updated type date
      id=$(json_get "$block" "id")
      public=$(json_get "$block" "public")
      updated=$(json_get "$block" "updated_at")
      [[ -z "$id" ]] && continue
      type="secret"
      [[ "$public" == "true" ]] && type="public"
      if [[ -n "$updated" ]]; then
        date=$(date -d "$updated" +"%Y/%m/%d(%a) %H:%M:%S" 2>/dev/null || echo "$updated")
      else
        date="(unknown)"
      fi
      echo "$id [$type] $date"
    done
}

# ----------------------------------------------------------------------
# Command handlers
# ----------------------------------------------------------------------

handle_repo() {
  case "$SUBCOMMAND" in
    list)      repo_list ;;
    create)    repo_create "$1" ;;
    delete)    repo_delete "$1" ;;
    private)   repo_private "$1" ;;
    public)    repo_public "$1" ;;
    rename)    repo_rename "$1" "$2" ;;
    push)      repo_push "$1" "$2" "${@:3}" ;;
    tree)      repo_tree "$1" "$2" ;;
    diff)      repo_diff "$1" "$2" ;;
    pages)     repo_pages "$1" "$2" "$3" ;;
    *)         usage ;;
  esac
}

handle_gist() {
  local desc_opt="" gist_id_opt=""
  local files=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d) desc_opt="$2"; shift 2 ;;
      -i) gist_id_opt="$2"; shift 2 ;;
      *) files+=("$1"); shift ;;
    esac
  done
  case "$SUBCOMMAND" in
    list)   gist_list ;;
    delete) gist_delete "$gist_id_opt" ;;
    public) gist_upload "public" "$desc_opt" "$gist_id_opt" "${files[@]}" ;;
    secret) gist_upload "private" "$desc_opt" "$gist_id_opt" "${files[@]}" ;;
    *)      usage ;;
  esac
}



# ----------------------------------------------------------------------
# Release operation
# ----------------------------------------------------------------------

release_repo() {
  require_user
  local name="$1"
  require_repo "$name"

  echo "Releasing current repo to https://github.com/$USERNAME/$name (reset history)..."

  # 現在のローカルリポジトリの絶対パスを取得
  local SRC_DIR
  SRC_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

  # 一時ディレクトリを作成
  local TMPDIR
  TMPDIR="$(mktemp -d)"
  echo "Temporary dir: $TMPDIR"

  # tracked ファイルをアーカイブとしてコピー
  (
    cd "$SRC_DIR"
    git archive --format=tar HEAD | tar -x -C "$TMPDIR"
  )

  # 一時ディレクトリに移動して新しいリポジトリ作成
  cd "$TMPDIR"
  git init -q
  git config user.name "$USERNAME"
  git config user.email "${USERNAME}@users.noreply.github.com"
  git remote add origin "https://github.com/$USERNAME/${name}.git"

  git add .
  local DATE_STR
  #DATE_STR=$(date +%Y-%m-%d)
  #git commit -m "Release ${DATE_STR}"
  GIT_COMMITTER_DATE="2023-01-01T00:00:00" \
  GIT_AUTHOR_DATE="2023-01-01T00:00:00" \
  git commit -m "Release"
  git branch -M main
  git push -f origin main

  cd "$SRC_DIR"
  rm -rf "$TMPDIR"
  echo "Released successfully to https://github.com/$USERNAME/$name"
}


# ----------------------------------------------------------------------
# Status checker (Contribution graph visibility)
# ----------------------------------------------------------------------

check_status() {
  local users emails_resp graph_resp noreply_status graph_status
  users=$(grep -oE 'https://([^:]+):' "$CRED_FILE" | sed 's|https://||;s|:||')
  for user in $users; do
    USERNAME="$user"
    API_TOKEN=$(grep -F "https://$user:" "$CRED_FILE" | sed -E "s|https://$user:([^@]+)@.*|\1|" | head -n 1)

    # check emails
    emails_resp=$(curl_api "$API/user/emails")
    echo $emails_resp

    if echo "$emails_resp" | grep -q '"status": "404"'; then
      noreply_status="404"
    elif echo "$emails_resp" | grep -qE "\"email\"[[:space:]]*:[[:space:]]*\"[0-9]+\+$user@users\.noreply\.github\.com\""; then
      noreply_status="ON"
    else
      noreply_status="OFF"
    fi

    # check contribution graph visibility
    graph_resp=$(curl_api "$API/users/$user")
    if echo "$graph_resp" | grep -q '"contributions_collection":'; then
      graph_status="VISIBLE"
    else
      graph_status="HIDDEN"
    fi

    echo "$user: noreply=$noreply_status graph=$graph_status"
  done
}


# ----------------------------------------------------------------------
# Global variables
# ----------------------------------------------------------------------

API="https://api.github.com"
USERNAME=""
API_TOKEN=""
ACTION=""
SUBCOMMAND=""
CRED_FILE="$HOME/.git-credentials"

# ----------------------------------------------------------------------
# Main script body
# ----------------------------------------------------------------------

# Parse options
while [[ "$#" -gt 0 && "$1" =~ ^- ]]; do
  case "$1" in
    -u|--user)
      USERNAME="$2"
      shift 2 ;;
    --)
      shift; break ;;
    *)
      echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

ACTION="${1:-}"
SUBCOMMAND="${2:-}"
shift $(( $# > 1 ? 2 : $# ))

#if [[ ! -f "$CRED_FILE" ]]; then
#  echo "Error: $CRED_FILE not found."
#  echo "Run: git config --global credential.helper store"
#  exit 1
#fi

case "$ACTION" in
  repo) handle_repo "$@" ;;
  gist) handle_gist "$@" ;;
  noreply) noreply ;;
  iam) set_iam "$SUBCOMMAND" ;;
  status) check_status ;;
  release) release_repo "$@" ;;
  *) usage ;;
esac

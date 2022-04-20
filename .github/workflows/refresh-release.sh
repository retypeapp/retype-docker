#!/bin/bash

# TODO: edge case (unlikely): update the release only and only if the
#       respective major tag (e.g. v2) was pushed.

github_token=""
path_prefix="src"

# GitHub committer info (name + email)
git_user_name="New Release bot"
git_user_email="hello+retypeapp-docker-images@retype.com"

dh_org="retypeapp"

# DockerHub repositories within retypeapp/ (${dh_org}/) to create Dockerfiles for
dh_repos=("retype") # watch, nginx, lighttpd, apache...

# Names to compose the tags
dotnet_ver="6.0"
distromap=(alpine debian:bullseye-slim ubuntu:focal)
archmap=(amd64 arm64:arm64v8 arm32:arm32v7)

declare -A dockerfiles

# Define Dockerfile bases for every repository. The '<MSTAG>' placeholder will
# be replaced with the equivalent microsoft tag. '<RETYPETAG>' is replaced with
# retype's native tag.
# <MSTAG> => 6.0-bullseye-arm64v8
# <RETYPETAG> => 2.3.0-debian-arm64
dockerfiles["retype"]="FROM mcr.microsoft.com/dotnet/aspnet:<MSTAG>
WORKDIR /retype

# Instructs Retype to listen on all interfaces unless otherwise specified
# in the config file or --host argument during watch and run commands.
ENV RETYPE_DEFAULT_HOST=\"0.0.0.0\"

ADD . /"

function fail() {
 >&2 echo "::error::${@}"
 exit 1
}

function fail_group() {
 echo "::endgroup::"
 fail "${@}"
}

for param in "${@}"; do
 case "${param}" in
  '--github-token='*) github_token="${param#*=}";;
  *) fail "Unknown argument '${param}'.";;
 esac
done

if [ ${#github_token} -lt 10 ]; then
 fail "GitHub token (--github-token) is invalid."
fi

echo "- Querying latest Retype release from nuget.org/packages/retypeapp..."
result="$(curl -si https://www.nuget.org/packages/retypeapp)" || \
 fail "Unable to fetch retype package page from nuget.org website."

if [ "$(echo "${result}" | head -n1 | cut -f2 -d" ")" != 200 ]; then
 echo "Failed query for latest Retype release in NuGet website.
::group::HTTP response output
${result}
::endgroup::"

 httpstat="$(echo "${result}" | head -n1 | cut -f2 -d" ")"
 fail "HTTP response ${httpstat} received while trying to query latest Retype Release from NuGet."
fi

latest="$(echo "${result}" | egrep '\| retypeapp ' | sed -E "s/^.*\| retypeapp //" | head -n1 | strings)"

if [ -z "${latest}" ]; then
 fail "Unable to extract latest version number from NuGet website."
elif ! echo "${latest}" | egrep -q '^([0-9]+\.){2}[0-9]+$'; then
 fail "Invalid version number extracted from NuGet website: ${latest}"
fi

major="${latest%%.*}"
majorminor="${latest%.*}"
minor="${majorminor#*.}"
build="${latest##*.}"
latest_re="${latest//\./\\\.}"

echo " Version ${latest}."

echo "- Generating 'Dockerfile' files..."

release_body="# Dockerfiles for this release\\n\\nBelow is a list of all Dockerfiles specific to this Retype Docker Images release."
for repo in "${dh_repos[@]}"; do
 fullrepo="${dh_org}/${repo}"
 if [ -z "${dockerfiles[${repo}]}" ]; then
  fail "No dockerfile determined for repo: ${fullrepo}"
 fi

 echo "::group::Dockerfiles for repository: ${fullrepo}"
 release_body+="\\n\\n## DockerHub ${fullrepo}\\n\\nDockerHub repository: [${fullrepo}](https://hub.docker.com/r/${fullrepo})\\n"
 tagcount=0
 for ver in latest ${major}{,/${majorminor}{,/${latest}}}; do
  for distro in "" "${distromap[@]}"; do
   for arch in "" "${archmap[@]}"; do
    dfpath="${path_prefix}"
    if [ ! -z "${dfpath}" ]; then
     dfpath+="/"
    fi
    dfpath+="${repo}/${ver}"

    # even if 'latest' we'll point to our specific dotnet ver to ensure
    # Retype works with that Dockerfile.
    mstag="${dotnet_ver}"
    retypetag="${ver##*/}"
    if [ ! -z "${distro}" ]; then
     dfpath+="/${distro%%:*}"
     mstag+="-${distro#*:}"
     retypetag+="-${distro%%:*}"
    fi

    if [ ! -z "${arch}" ]; then
     dfpath+="/${arch%%:*}"
     mstag+="-${arch#*:}"
     retypetag+="-${arch%%:*}"
    fi

    if [ ! -z "${dfpath}" ]; then
     mkdir -p "${dfpath}" || fail "Unable to create directory: ${dfpath}"
    fi

    echo "${retypetag} (${mstag})"
    echo "${dockerfiles[${repo}]}" | sed -E "s/<MSTAG>/${mstag}/g;s/<RETYPETAG>/${retypetag}/g" > \
     "${dfpath}/Dockerfile" || fail "Unable to create Dockerfile: ${dfpath}/Dockerfile"
    tagcount="$(( 10#${tagcount} + 1 ))"

    release_body+="\\n- [${retypetag}](../v${latest}/${dfpath}/Dockerfile)"
   done
  done
 done
 release_body+="\\n\\nTotal tags: ${tagcount}"
 echo "Total tags for ${fullrepo}: ${tagcount}"
 echo "::endgroup::"
done

if [ ! -z "$(git status --porcelain)" ]; then
 echo "::group::Committing files..."
 git add "${path_prefix}" || fail_group "Unable to stage introduced files for committing."
 git config user.name "${git_user_name}" || fail_group "Unable to setup git committer username."
 git config user.email "${git_user_email}" || fail_group "Unable to setup git committer email."
 git commit -m "Add Dockerfiles for Retype version ${latest}." || fail_group "Unable to commit changed files."
 git push origin HEAD || fail_group "Unable to push changes back to GitHub."
 echo "::endgroup::"
fi

echo "::group::Fetching tags..."
git fetch --tag || fail_group "Unable to fetch tags from origin."
echo "::endgroup::"

echo "Querying releases..."
# FIXME: implement multi-page support
releases_query="$(curl --silent --include \
 --header 'accept: application/vnd.github.v3+json' \
 --header 'authorization: Bearer '"${github_token}" \
 "${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/releases" 2>&1)" || \
 fail "Unable to fetch list of releases. Curl command returned non-zero exit status."

if [ "$(echo "${releases_query}" | head -n1 | cut -f2 -d" ")" != 200 ]; then
 echo "Failed query for releases in GitHub.
::group::HTTP response output
${releases_query}
::endgroup::"
 fail "HTTP non-OK result status from releases query."
fi

_ifs="${IFS}"
# four spaces are matched here because the return is an array with objects
varnames=(tag_name draft name id html_url)
IFS=$'\n'
releases_data=($(echo "${releases_query}" | egrep "^    \"($(IFS='|'; echo "${varnames[*]}"))\": "))
IFS="${_ifs}"
found_rel=false
republish=false
declare -A var_read gh_rel
for line in "${releases_data[@]}"; do
 var_name="${line%%\":*}"
 var_name="${var_name#*\"}"
 var_data="${line#*\": }"

 if [ "${var_data: -1}" == "," ]; then
  var_data="${var_data::-1}"
 fi
 if [ "${var_data::1}" == '"' ]; then
  var_data="${var_data:1:-1}"
 fi

 var_read[${var_name}]=true
 gh_rel[${var_name}]="${var_data}"

 all_read=true
 for var in "${varnames[@]}"; do
  if [ "${var_read[${var}]}" != "true" ]; then
   all_read=false
   break
  fi
 done

 if $all_read; then
  if [ "${gh_rel[tag_name]}" == "v${latest}" ]; then
   found_rel=true
   if [ "${gh_rel[draft]}" == "false" ]; then
    republish=true
   fi
   break
  fi
  for var in "${varnames[@]}"; do
   var_read[${var}]=false
  done
 fi
done

if ${found_rel}; then
 if [ -z "${gh_rel[id]}" ]; then
  fail "Found release but GitHub release ID was not properly filled in."
 fi

 if ${republish}; then
  echo "Found active release '${gh_rel[name]}' for tag: v${latest}"
 else
  echo "Found draft release '${gh_rel[name]}' for tag: v${latest}"
 fi
 echo "Release URL: ${gh_rel[html_url]}"
else
 echo "No current release for v${major} tag. Will create a new one."
fi

echo "::group::Checking tags..."
currsha="$(git log -n1 --pretty='format:%H')"

outdated_tags=()
missing_tags=()

# there's a %(HEAD) format in git command to show an '*' if the major tag matches current checked out
# ref, but it seems it does not work, so let's not rely on it
existing_taghashes="$(git tag --format='%(objectname):%(refname:strip=2)')"

existing_tag="$(echo "${existing_taghashes}" | egrep "^[^:]+:v${latest//\./\\.}\$")"

tag_status="updated"
if [ -z "${existing_tag}" ]; then
 tag_status="missing"
 echo "- v${latest}: missing"
elif [ "${existing_tag%%:*}" != "${currsha}" ]; then
 tag_status="outdated"
 echo "- v${latest}: outdated"
else
 echo "- v${latest}: updated"
fi
echo "::endgroup::"

case "${tag_status}" in
 "outdated")
  echo "::group::Removing local and remote copies of outdated version tag..."
  git push origin ":v${latest}" || fail_group "Unable to remove the version tag 'v${latest}' from the repository."
  git tag -d "v${latest}" || fail_group "Unable to delete the version tag 'v${latest}' from local git repository."
  echo "::endgroup::"

  git tag "v${latest}" || fail_group "Unable to create tag: v${latest}"
  ;;
 "missing")
  echo "Creating version tag..."
  git tag "v${latest}" || fail "Unable to create tag: v${latest}"
  ;;
 "updated")
  echo "Version tag is already latest Retype version. No changes needed in tags."

  if ${found_rel} && ${republish}; then
   # Release is not in "draft" state, so we don't even need to publish it.
   echo "::warning::Release already up-to-date: ${gh_rel[html_url]}"
   exit 0
  fi
  ;;
esac

if [ "${tag_status}" != "updated" ]; then
 echo "::group::Pushing version tag..."
 git push origin "v${latest}" || fail_group "Unable to push tag back to GitHub."
 echo "::endgroup::"
fi

if ${found_rel}; then
 if ${republish}; then
  publishmsg="Re-publishing"
  donepubmsg="Existing Release re-published"
 else
  publishmsg="Publishing existing draft"
  donepubmsg="Existing Draft Release published"
 fi

 echo "${publishmsg} release for v${latest} (latest) tag: ${gh_rel[name]}"

 # API endpoint docs
 # https://docs.github.com/en/rest/reference/repos#update-a-release (set "draft" to false)
 result="$(curl --silent --include --request PATCH \
  --header 'accept: application/vnd.github.v3+json' \
  --header 'authorization: Bearer '"${github_token}" \
  "${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/releases/${gh_rel[id]}" \
  --data '{
  "tag_name": "v'"${latest}"'",
  "name": "Version '"${latest}"'",
  "body": "'"${release_body}"'",
  "draft": false,
  "prerelease": false
 }' 2>&1)" || \
 fail "Unable to create GitHub release. Curl command returned non-zero exit status."

 result_stat="$(echo "${result}" | head -n1 | cut -f2 -d" ")"

 if [ "${result_stat}" != 200 ]; then
  echo "Failed query to update release in GitHub.
::group::HTTP response output
${result}
::endgroup::"
  fail "Received HTTP response code ${result_stat} while 200 (ok) was expected."
 fi

 # two spaces are matched because response is a single object; thus one indent space
 release_url="$(echo "${result}" | egrep "^  \"html_url\": \"" | head -n1 | cut -f4 -d\")"

 if [ -z "${release_url}" ]; then
  fail "Unable to fetch updated release URL from GitHub response. We cannot tell the release was properly updated."
 fi

 echo "::warning::${donepubmsg}: ${release_url}"
else
 echo "Creating GitHub release for tag: v${latest}"

 # API endpoint docs
 # https://docs.github.com/en/rest/reference/repos#create-a-release
 result="$(curl --silent --include --request POST \
  --header 'accept: application/vnd.github.v3+json' \
  --header 'authorization: Bearer '"${github_token}" \
  "${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/releases" \
  --data '{
  "tag_name": "v'"${latest}"'",
  "name": "Version '"${latest}"'",
  "body": "'"${release_body}"'",
  "draft": false,
  "prerelease": false
 }' 2>&1)" || \
 fail "Unable to create GitHub release. Curl command returned non-zero exit status."

 result_stat="$(echo "${result}" | head -n1 | cut -f2 -d" ")"

 if [ "${result_stat}" != 201 ]; then
  echo "Failed query to create new release in GitHub.
::group::HTTP response output
${result}
::endgroup::"
  fail "Received HTTP response code ${result_stat} while 201 (created) was expected."
 fi

 # two spaces are matched because response is a single object; thus one indent space
 release_url="$(echo "${result}" | egrep "^  \"html_url\": \"" | head -n1 | cut -f4 -d\")"

 if [ -z "${release_url}" ]; then
  fail "Unable to fetch release URL from GitHub response. We cannot tell the release was made."
 fi

 echo "::warning::Release created: ${release_url}"
fi
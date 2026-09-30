#!/usr/bin/env bash
# Applies Zitadel's instance-wide settings through its API: no self-registration, a lockout after
# failed attempts, two-factor authentication for the instance administrators, and the names of the
# admin and of the service account it runs as. Changes only what differs, so it can run on every deploy.
#
# Environment:
#   ZITADEL_URL          e.g. https://auth.example.net
#   ZITADEL_TOKEN        personal access token of the automation service account (instance owner)
#   ZITADEL_ADMIN_EMAIL  email address of the first admin
set -euo pipefail

: "${ZITADEL_URL:?}" "${ZITADEL_TOKEN:?}" "${ZITADEL_ADMIN_EMAIL:?}"
admin_org=Harbor
automation_user=automation

fail() { echo "$*" >&2; exit 1; }

# api METHOD PATH [BODY [ORG_ID]]
api() {
  local args=(-sS --fail-with-body -X "$1" "$ZITADEL_URL$2"
    -H "Authorization: Bearer $ZITADEL_TOKEN" -H "Content-Type: application/json")
  [[ -n ${3:-} ]] && args+=(--data "$3")
  [[ -n ${4:-} ]] && args+=(-H "x-zitadel-orgid: $4")
  local response
  if ! response=$(curl "${args[@]}"); then
    echo "zitadel: $1 $2 failed: $response" >&2
    return 1
  fi
  printf '%s\n' "$response"
}

# True when every field of the desired JSON object already has that value in the current one.
# Zitadel leaves out fields that hold their default (false, 0, ""), and sends 64-bit numbers as strings.
matches() {
  jq -e --argjson desired "$2" '
    . as $current | all($desired | to_entries[];
      (($current[.key] // (if .value | type == "boolean" then false elif .value | type == "number" then 0 else "" end)) | tostring)
        == (.value | tostring))' <<<"$1" >/dev/null
}

login_fields='allowUsernamePassword allowRegister allowExternalIdp forceMfa passwordlessType
  hidePasswordReset ignoreUnknownUsernames defaultRedirectUri passwordCheckLifetime
  externalLoginCheckLifetime mfaInitSkipLifetime secondFactorCheckLifetime multiFactorCheckLifetime
  allowDomainDiscovery disableLoginWithEmail disableLoginWithPhone forceMfaLocalOnly'

# The whole login policy with the desired fields applied: updates replace the policy.
login_policy_body() {
  jq -c --arg fields "$login_fields" --argjson desired "$2" '
    with_entries(select(.key as $key | $fields | split(" ") | map(select(. != "")) | index($key))) + $desired' <<<"$1"
}

# The factors an organization's users can choose from; an organization's own policy starts with none.
ensure_factors() {
  local org=$1 type current
  current=$(api POST /management/v1/policies/login/second_factors/_search '{}' "$org" | jq -r '[.result[]?] | join(" ")')
  for type in SECOND_FACTOR_TYPE_OTP SECOND_FACTOR_TYPE_U2F; do
    [[ " $current " == *" $type "* ]] && continue
    api POST /management/v1/policies/login/second_factors "{\"type\": \"$type\"}" "$org" >/dev/null
    echo "zitadel: second factor $type allowed"
  done
  current=$(api POST /management/v1/policies/login/auth_factors/_search '{}' "$org" | jq -r '[.result[]?] | join(" ")')
  for type in MULTI_FACTOR_TYPE_U2F_WITH_VERIFICATION; do
    [[ " $current " == *" $type "* ]] && continue
    api POST /management/v1/policies/login/multi_factors "{\"type\": \"$type\"}" "$org" >/dev/null
    echo "zitadel: multi-factor $type allowed"
  done
}

for _ in {1..24}; do
  curl -sf -o /dev/null "$ZITADEL_URL/debug/ready" && break
  sleep 5
done
curl -sf -o /dev/null "$ZITADEL_URL/debug/ready" || fail "Zitadel at $ZITADEL_URL is not ready"

# Instance defaults, which every organization inherits unless it has its own policy.
desired='{"allowRegister": false, "allowExternalIdp": false, "ignoreUnknownUsernames": true}'
policy=$(api GET /admin/v1/policies/login | jq -c .policy)
if matches "$policy" "$desired"; then
  echo "zitadel: default login policy unchanged"
else
  api PUT /admin/v1/policies/login "$(login_policy_body "$policy" "$desired")" >/dev/null
  echo "zitadel: default login policy updated (no self-registration)"
fi

desired='{"maxPasswordAttempts": 5, "maxOtpAttempts": 5}'
policy=$(api GET /admin/v1/policies/lockout | jq -c .policy)
if matches "$policy" "$desired"; then
  echo "zitadel: lockout policy unchanged"
else
  api PUT /admin/v1/policies/password/lockout "$desired" >/dev/null
  echo "zitadel: lockout policy updated"
fi

# Instance administrators sign in with a second factor.
org_id=$(api POST /admin/v1/orgs/_search \
  "$(jq -nc --arg name "$admin_org" '{queries: [{nameQuery: {name: $name, method: "TEXT_QUERY_METHOD_EQUALS"}}]}')" |
  jq -r '.result[0].id // empty')
[[ -n $org_id ]] || fail "Organization $admin_org not found"
desired='{"allowRegister": false, "allowExternalIdp": false, "forceMfa": true, "ignoreUnknownUsernames": true}'
policy=$(api GET /management/v1/policies/login "" "$org_id" | jq -c .policy)
if [[ $(jq -r '.isDefault // false' <<<"$policy") == true ]]; then
  api POST /management/v1/policies/login "$(login_policy_body "$policy" "$desired")" "$org_id" >/dev/null
  echo "zitadel: $admin_org login policy created (two-factor required)"
elif matches "$policy" "$desired"; then
  echo "zitadel: $admin_org login policy unchanged"
else
  api PUT /management/v1/policies/login "$(login_policy_body "$policy" "$desired")" "$org_id" >/dev/null
  echo "zitadel: $admin_org login policy updated (two-factor required)"
fi
ensure_factors "$org_id"

# The admin's email address; there is no mail server to verify it with, so it is set as verified.
domain=${ZITADEL_URL#*://}
domain=${domain%%[:/]*}
admin=$(api POST /v2/users \
  "$(jq -nc --arg name "admin@${admin_org,,}.$domain" '{queries: [{loginNameQuery: {loginName: $name}}]}')" |
  jq -c '.result[0] // empty')
[[ -n $admin ]] || fail "Admin user admin@${admin_org,,}.$domain not found"
current_email=$(jq -r '.human.email.email' <<<"$admin")
if [[ ${current_email,,} == "${ZITADEL_ADMIN_EMAIL,,}" ]]; then
  echo "zitadel: admin email unchanged"
else
  api PUT "/management/v1/users/$(jq -r .userId <<<"$admin")/email" \
    "$(jq -nc --arg email "$ZITADEL_ADMIN_EMAIL" '{email: $email, isEmailVerified: true}')" "$org_id" >/dev/null
  echo "zitadel: admin email set"
fi

# The service account this runs as.
me=$(api GET /auth/v1/users/me | jq -c .user)
if [[ $(jq -r .userName <<<"$me") == "$automation_user" ]]; then
  echo "zitadel: service account name unchanged"
else
  api PUT "/management/v1/users/$(jq -r .id <<<"$me")/username" \
    "$(jq -nc --arg name "$automation_user" '{userName: $name}')" "$org_id" >/dev/null
  echo "zitadel: service account renamed to $automation_user"
fi

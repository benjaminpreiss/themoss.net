# Called once per repository; -e makes every policy failure nonzero.
. as $policy
| $policy.repositories[$repo] as $expected
| $effective[0] as $effectiveRules
| def active: .enforcement == "active" and .target == "branch";
  def allbranches: active and .conditions.ref_name.include == ["~ALL"] and .conditions.ref_name.exclude == [];
  def defaultOnly: active and .conditions.ref_name.include == ["~DEFAULT_BRANCH"] and .conditions.ref_name.exclude == [];
  def required: [ $effectiveRules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]? | .context ] | unique;
  def prs: [ $effectiveRules[] | select(.type == "pull_request") ];
  ($expected != null)
  and (prs | length > 0)
  and any($rules[]; defaultOnly and any(.rules[]; .type == "pull_request"))
  and all($rules[]; if active and any(.rules[]; .type == "pull_request") then defaultOnly else true end)
  and any(prs[]; (.parameters.required_approving_review_count // -1) >= $expected.minApprovals and .parameters.dismiss_stale_reviews_on_push == true)
  and all($expected.requiredChecks[]; . as $check | required | index($check) != null)
  and any($rules[]; allbranches and any(.rules[]; .type == "non_fast_forward"))
  and any($rules[]; allbranches and any(.rules[]; .type == "deletion"))
  and all($rules[]; (.bypass_actors | all(.[]; .actor_type != "Integration" or .actor_id != $app)))

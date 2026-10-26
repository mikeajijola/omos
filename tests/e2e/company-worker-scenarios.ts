// Each scenario owns its profile, provider, company repository, and image pool.
// Split measured production workloads across independent namespace runners.
export const companyWorkerScenarios = [
  { id: "files", title: "file proposals", group: 1 },
  { id: "desired", title: "continuous desired capability reconciliation", group: 1 },
  { id: "input", title: "authenticated human input in the isolated worker", group: 1 },
  { id: "answer", title: "answers without file changes", group: 1 },
  { id: "recovery", title: "recovered internal checkpoints", group: 1 },
  { id: "archive_recovery", title: "archive recovery without replaying the actor", group: 2 },
  { id: "partial_recovery", title: "the retained native session after interruption before an answer", group: 2 },
  { id: "retirement", title: "passive public history retention after cancellation", group: 2 },
  { id: "amendment", title: "an authenticated task amendment in the retained native session", group: 2 },
  { id: "amend_after_answer", title: "an authenticated amendment after a private answer while preserving unaffected files", group: 3 },
  { id: "projection", title: "ordinary projected file edits and deletions", group: 3 },
  { id: "coding", title: "successful coding checks", group: 3 },
  { id: "coding_recovery", title: "coding recovery after retained failed checks", group: 3 },
  { id: "coding_failure", title: "failed coding checks without publication", group: 3 },
] as const;

export function companyWorkerScenarioName(scenario: { title: string; group: number }) {
  return `the production company coordinator runs isolated native work and independently verifies ${scenario.title} [isolation group ${scenario.group}]`;
}

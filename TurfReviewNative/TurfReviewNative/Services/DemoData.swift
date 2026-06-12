import Foundation

enum DemoData {
  static let items: [ReviewItem] = [
    ReviewItem(
      databaseID: 1,
      slug: "kitchenlux-send-plan",
      title: "KitchenLux outbound send plan",
      category: "outreach",
      status: "pending",
      decision: nil,
      actions: ReviewActionList(["Send", "Edit", "Kill"]),
      feedback: nil,
      renderedHTML: sampleHTML,
      markdown: nil,
      contentLength: 2400,
      actionStatus: nil,
      actionMessage: nil,
      approvalStatus: nil,
      approvalMessage: nil,
      ttsStatus: "ready",
      contextStatus: "ready",
      contextSummary: "Approve a concise outbound campaign, check the follow-up timing, and call out any missing recipient detail.",
      decisionSchemaVersion: 3,
      createdAt: "2026-06-11 09:10:00",
      updatedAt: "2026-06-11 09:10:00"
    ),
    ReviewItem(
      databaseID: 2,
      slug: "openclaw-followup",
      title: "OpenClaw implementation follow-up",
      category: "general",
      status: "pending",
      decision: nil,
      actions: ReviewActionList(["Noted", "Execute", "Inbox", "Rework", "Kill"]),
      feedback: nil,
      renderedHTML: """
      <h2>Requested decision</h2>
      <p>Decide whether Benji should execute the implementation path, move it into OmniFocus, or ask for a rework pass.</p>
      <ul>
        <li>Primary risk: the source path needs verification before execution.</li>
        <li>Recommended next action: execute only if the proof target is clear.</li>
      </ul>
      """,
      markdown: nil,
      contentLength: 900,
      actionStatus: nil,
      actionMessage: nil,
      approvalStatus: nil,
      approvalMessage: nil,
      ttsStatus: "skipped",
      contextStatus: "ready",
      contextSummary: "This review asks for a decision on an agent follow-up with a source verification risk.",
      decisionSchemaVersion: 3,
      createdAt: "2026-06-11 08:25:00",
      updatedAt: "2026-06-11 08:25:00"
    ),
    ReviewItem(
      databaseID: 3,
      slug: "plume-feedback-archive",
      title: "Plume feedback archive",
      category: "admin",
      status: "archived",
      decision: "Noted",
      actions: ReviewActionList(["Noted", "Execute", "Inbox", "Rework", "Kill"]),
      feedback: "Captured for the next version log.",
      renderedHTML: "<p>The release-track feedback was captured and archived.</p>",
      markdown: nil,
      contentLength: 300,
      actionStatus: "succeeded",
      actionMessage: "Noted and archived.",
      approvalStatus: "succeeded",
      approvalMessage: "Noted and archived.",
      ttsStatus: "skipped",
      contextStatus: "skipped",
      contextSummary: nil,
      decisionSchemaVersion: 3,
      createdAt: "2026-06-10 16:00:00",
      updatedAt: "2026-06-10 16:30:00"
    )
  ]

  static let annotations: [ReviewAnnotation] = [
    ReviewAnnotation(
      id: 1,
      slug: "kitchenlux-send-plan",
      quote: "Target send date",
      anchorType: "text",
      anchorRef: "char:195",
      comment: "Check this against the live calendar before approving.",
      createdAt: "2026-06-11 09:20:00"
    )
  ]

  static let requests: [DecisionRequest] = [
    DecisionRequest(
      id: 42,
      slug: "plume-feedback-archive",
      kind: "agent_followup",
      summary: "Capture the feedback in the next-version log.",
      sensitivity: "normal",
      status: "succeeded",
      proofJSON: #"{"summary":"Feedback log updated"}"#,
      confirmationSlug: nil,
      lastError: nil,
      updatedAt: "2026-06-10 16:30:00"
    )
  ]

  static let sampleHTML = """
  <h2>Decision needed</h2>
  <p>Approve the outbound email copy, visible recipients, and target send date. The plan is ready, but the send should only proceed if the follow-up timing still matches the current campaign window.</p>
  <h3>Send plan</h3>
  <table>
    <thead><tr><th>Field</th><th>Value</th></tr></thead>
    <tbody>
      <tr><td>To</td><td>Warm KitchenLux leads in the chef-owner segment</td></tr>
      <tr><td>Subject</td><td>A cleaner way to stock premium home kitchens</td></tr>
      <tr><td>Target send date</td><td>Friday morning</td></tr>
    </tbody>
  </table>
  <h3>Copy</h3>
  <p>Hi there, I noticed your team is expanding the private dining side of the business. KitchenLux can package the premium cookware set, delivery, and replenishment workflow so the kitchen team has less admin before each event.</p>
  <blockquote>Recommended decision: Send, with a short note if the Friday timing should move.</blockquote>
  """
}

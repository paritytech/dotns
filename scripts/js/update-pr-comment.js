// Shared PR comment updater for all CI workflows.
// Updates a single collapsible section in the shared CI Summary comment.
//
// Required env vars:
//   SECTION     - section name (e.g. "Contract Tests", "Gas Report")
//   RESULT      - one-line result text
//   REPORT_URL  - (optional) link to HTML report on GitHub Pages
//   RUN_ID      - GitHub Actions run ID for logs link
//   REPO        - full repo name (owner/repo)
//   DETAILS_FILE - (optional) path to markdown file for collapsible content

module.exports = async ({ github, context }) => {
  const fs = require("fs");
  const marker = "<!-- ci-summary -->";
  const section = process.env.SECTION;
  const result = process.env.RESULT || "Failed";
  const reportUrl = process.env.REPORT_URL || "";
  const runId = process.env.RUN_ID;
  const repoFull = process.env.REPO;
  const detailsFile = process.env.DETAILS_FILE || "";
  const logsUrl = `https://github.com/${repoFull}/actions/runs/${runId}`;

  let details = "";
  if (detailsFile) {
    try {
      details = fs.readFileSync(detailsFile, "utf8").trim();
    } catch {}
  }

  const { owner, repo } = context.repo;
  const issue_number = context.payload.pull_request.number;

  const comments = await github.paginate(github.rest.issues.listComments, {
    owner,
    repo,
    issue_number,
    per_page: 100,
  });

  const existing = comments.find(
    (c) => c.user?.login === "github-actions[bot]" && c.body?.includes(marker)
  );

  // Parse existing sections from the comment
  let sections = {};
  if (existing?.body) {
    const sectionRegex =
      /<details>\s*<summary><strong>([^<]+)<\/strong>\s*-\s*([^<]*?)(?:<a[^>]*>View Report<\/a>)?\s*<\/summary>([\s\S]*?)<\/details>/g;
    let match;
    while ((match = sectionRegex.exec(existing.body)) !== null) {
      sections[match[1].trim()] = {
        result: match[2].trim(),
        content: match[3].trim(),
      };
    }
  }

  // Build this section's summary line
  let summaryLine = result;
  if (reportUrl) {
    summaryLine += ` - <a href="${reportUrl}">View Report</a>`;
  }

  // Build this section's content
  let sectionContent = "";
  if (details) {
    sectionContent = `\n\n${details}\n\n`;
  }
  sectionContent += `\n[View Logs](${logsUrl})\n`;
  if (reportUrl) {
    sectionContent += `[View Full Report](${reportUrl})\n`;
  }

  sections[section] = {
    result: summaryLine,
    content: sectionContent,
  };

  // Rebuild the comment
  const order = [
    "4naly3er Analysis",
    "Slither Analysis",
    "Contract Tests",
    "Gas Report",
    "Coverage",
    "Documentation",
    "Format & Lint",
    "Deploy Contracts",
    "PR Title",
    "Labels",
  ];

  const sortedKeys = Object.keys(sections).sort((a, b) => {
    const ai = order.indexOf(a);
    const bi = order.indexOf(b);
    return (ai === -1 ? 999 : ai) - (bi === -1 ? 999 : bi);
  });

  let body = `${marker}\n## CI Summary\n\n`;
  for (const key of sortedKeys) {
    const sec = sections[key];
    body += `<details>\n<summary><strong>${key}</strong> - ${sec.result}</summary>\n${sec.content}\n</details>\n\n`;
  }

  if (existing) {
    await github.rest.issues.updateComment({
      owner,
      repo,
      comment_id: existing.id,
      body,
    });
  } else {
    await github.rest.issues.createComment({ owner, repo, issue_number, body });
  }
};

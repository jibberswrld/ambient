import type {
  AccountSummary,
  BackgroundTask,
  ConnectorApp,
  GateScreen,
  MemoryItem,
  OverlayDrawing,
  SkillSummary,
} from './contract';

// The scripted world the browser preview and the gallery run in. Content mirrors the Mac captures in docs/ui-captures
// so the two can be compared side by side.

const minutesAgo = (minutes: number) => new Date(Date.now() - minutes * 60_000).toISOString();
const hoursAgo = (hours: number) => minutesAgo(hours * 60);
const daysAgo = (days: number) => minutesAgo(days * 24 * 60);

export function sampleBackgroundTasks(): BackgroundTask[] {
  return [
    {
      id: '6f1c2a0e-1d34-4b7a-9a51-0c2f3b1d9e01',
      kind: 'codexAgent',
      title: 'Refactor the settings screen',
      status: 'running',
      workingDirectory: 'C:\\Users\\jabir\\code\\ambient',
      startedAt: minutesAgo(4.37),
      finishedAt: null,
      latestActivity: 'Editing SettingsView.tsx',
      result: null,
    },
    {
      id: '6f1c2a0e-1d34-4b7a-9a51-0c2f3b1d9e02',
      kind: 'shellCommand',
      title: 'Deploy the preview',
      status: 'failed',
      workingDirectory: 'C:\\Users\\jabir\\code\\site',
      startedAt: minutesAgo(12),
      finishedAt: minutesAgo(10.47),
      latestActivity: 'Building',
      result: 'The build stopped: a page imports a file that no longer exists.',
    },
    {
      id: '6f1c2a0e-1d34-4b7a-9a51-0c2f3b1d9e03',
      kind: 'shellCommand',
      title: 'Run the test suite',
      status: 'running',
      workingDirectory: 'C:\\Users\\jabir\\code\\ambient',
      startedAt: minutesAgo(0.68),
      finishedAt: null,
      latestActivity: '148 of 214 passed',
      result: null,
    },
    {
      id: '6f1c2a0e-1d34-4b7a-9a51-0c2f3b1d9e04',
      kind: 'ambientAgent',
      title: 'Summarise the launch thread',
      status: 'succeeded',
      workingDirectory: null,
      startedAt: minutesAgo(21),
      finishedAt: minutesAgo(19),
      latestActivity: 'Writing the summary',
      result:
        '## Launch thread\n\nPriya moved the review to **Thursday**. Pricing page is the only blocker.\n\n- Sam owns the onboarding copy and wants feedback by Wednesday.\n- The Fernhill invoice is due Friday and matches last month.\n- Nothing urgent in GitHub; three new low-priority issues in Linear.\n\nI kept Friday afternoon clear because you asked me to keep it for deep work. If the review runs long, Thursday 4pm is still open.',
    },
  ];
}

export const sampleTaskTranscript = `> Refactor the settings screen into one file per page.

Reading src\\settings\\SettingsView.tsx (488 lines)
Plan: split General, Connectors, Memory, Skills, Activity and Account into their own files.
Created src\\settings\\GeneralPage.tsx
Created src\\settings\\ConnectorsPage.tsx
Editing SettingsView.tsx`;

export function sampleMemoryItems(): MemoryItem[] {
  return [
    { id: 'a0000000-0000-4000-8000-000000000001', text: 'Keeps Friday afternoons free for deep work.', createdAt: hoursAgo(1), wasLearnedAutomatically: true },
    { id: 'a0000000-0000-4000-8000-000000000002', text: 'Prefers short replies, no greetings in drafts.', createdAt: daysAgo(1), wasLearnedAutomatically: true },
    { id: 'a0000000-0000-4000-8000-000000000003', text: 'Works on the Ambient repo in C:\\code\\ambient.', createdAt: daysAgo(3), wasLearnedAutomatically: false },
    { id: 'a0000000-0000-4000-8000-000000000004', text: 'Priya leads the launch; Sam owns onboarding copy.', createdAt: daysAgo(6), wasLearnedAutomatically: true },
    { id: 'a0000000-0000-4000-8000-000000000005', text: 'Pay invoices from Fernhill only after asking.', createdAt: daysAgo(8), wasLearnedAutomatically: false },
  ];
}

export function sampleSkills(): SkillSummary[] {
  return [
    { name: 'weekly-review', description: 'Every Friday: what shipped, what slipped, what is next.', isBuiltIn: false, directory: 'C:\\Users\\jabir\\AppData\\Roaming\\Ambient\\Skills\\weekly-review' },
    { name: 'inbox-triage', description: 'Sorts new email into reply, read later and ignore.', isBuiltIn: true, directory: 'builtin://inbox-triage' },
    { name: 'meeting-prep', description: 'Pulls notes, attendees and open threads before a meeting.', isBuiltIn: true, directory: 'builtin://meeting-prep' },
    { name: 'write-a-skill', description: 'Writes a new skill from something you showed Ambient how to do.', isBuiltIn: true, directory: 'builtin://write-a-skill' },
  ];
}

export function sampleConnectorApps(): ConnectorApp[] {
  const connectedSlugs = new Set(['github', 'gmail', 'googlecalendar']);
  const apps: [string, string][] = [
    ['github', 'GitHub'],
    ['gmail', 'Gmail'],
    ['googlecalendar', 'Google Calendar'],
    ['discord', 'Discord'],
    ['figma', 'Figma'],
    ['googledrive', 'Google Drive'],
    ['hubspot', 'HubSpot'],
    ['linear', 'Linear'],
    ['notion', 'Notion'],
    ['slack', 'Slack'],
    ['outlook', 'Outlook'],
    ['todoist', 'Todoist'],
  ];
  return apps.map(([slug, name]) => ({ slug, name, logoUrl: null, isConnected: connectedSlugs.has(slug) }));
}

export function sampleAccountSummary(): AccountSummary {
  const refillDate = new Date();
  refillDate.setMonth(refillDate.getMonth() + 1, 1);
  return {
    publikHandle: 'jabir',
    planName: 'Plus',
    usageRemainingFraction: 0.64,
    usageResetsOn: refillDate.toISOString(),
    manageAccountUrl: 'https://publikhq.com/wallet',
  };
}

export const sampleGateScreens: Record<'signIn' | 'waiting', GateScreen> = {
  signIn: {
    id: 'sign-in',
    title: 'Sign in to start',
    body: 'Ambient runs on your publik account. Sign in once and it works from any app on this PC.',
    note: 'No account yet? Creating one takes a minute.',
    isWaiting: false,
    buttons: [
      { action: 'create-account', label: 'Create an account', prominence: 'quiet' },
      { action: 'sign-in', label: 'Sign in with publik', prominence: 'primary' },
    ],
  },
  waiting: {
    id: 'waiting',
    title: 'Finish in your browser',
    body: 'We opened publik in your browser. Sign in there and Ambient picks it up on its own.',
    note: 'Waiting for you to sign in',
    isWaiting: true,
    buttons: [
      { action: 'cancel', label: 'Cancel', prominence: 'quiet' },
      { action: 'open-again', label: 'Open the page again', prominence: 'secondary' },
    ],
  },
};

export const sampleLongReply = `**This week**

Here is what needs you, in order:

1. **Launch review** moved to Thursday at 3pm. Priya wants the pricing page by then.
2. **Invoice from Fernhill** is due Friday. It matches last month, so I can pay it if you say so.
3. **Sam asked for feedback** on the onboarding copy in Slack. Two messages, both short.

The Codex agent finished the \`settings-refactor\` branch. All 214 tests pass and it opened a pull request.

- Nothing urgent in GitHub besides that.
- Linear has three new issues assigned to you, all low priority.

I left your Friday afternoon clear because you asked me to keep it for deep work. If the review runs long, I can move your 4:30 with Alex to Monday.`;

export const sampleMediumReply =
  'You have **two new emails** from Priya about the launch. She moved the review to *Thursday at 3pm* and asked whether the pricing page is ready.\n\nI drafted a reply saying yes and attached the latest link. Want me to send it?';

/** The drawing in docs/ui-captures/drawing/drawing-dark.png, in 1800×1120 capture pixels. */
export function sampleDrawing(): OverlayDrawing {
  return {
    captureWidth: 1800,
    captureHeight: 1120,
    annotations: [
      { shape: { kind: 'box', x: 1218, y: 118, width: 304, height: 74 }, text: 'Click Share', ink: 'ember', isFilled: false },
      { shape: { kind: 'arrow', tail: { x: 660, y: 656 }, tip: { x: 940, y: 494 } }, text: 'Then pick a person', ink: 'ember', isFilled: false },
      { shape: { kind: 'circle', center: { x: 320, y: 840 }, radius: 62 }, text: 'Send', ink: 'ember', isFilled: false },
      { shape: { kind: 'underline', from: { x: 1118, y: 860 }, to: { x: 1522, y: 860 } }, text: 'Link settings live here', ink: 'ember', isFilled: false },
      {
        shape: { kind: 'path', points: [{ x: 120, y: 180 }, { x: 120, y: 498 }, { x: 520, y: 498 }], isClosed: true },
        text: 'Right triangle',
        ink: 'red',
        isFilled: true,
      },
      {
        shape: { kind: 'path', points: [{ x: 120, y: 462 }, { x: 156, y: 462 }, { x: 156, y: 498 }], isClosed: false },
        text: null,
        ink: 'white',
        isFilled: false,
      },
    ],
  };
}

/** The step-by-step sketch in docs/ui-captures/drawing/sketch-light.png. */
export function sampleSketch(): OverlayDrawing {
  return {
    captureWidth: 1800,
    captureHeight: 1120,
    annotations: [
      { shape: { kind: 'path', points: [{ x: 600, y: 860 }, { x: 1200, y: 860 }], isClosed: false }, text: 'Draw a horizontal base', ink: 'yellow', isFilled: false },
      { shape: { kind: 'path', points: [{ x: 600, y: 860 }, { x: 600, y: 300 }], isClosed: false }, text: 'Draw a vertical side', ink: 'blue', isFilled: false },
      { shape: { kind: 'path', points: [{ x: 600, y: 300 }, { x: 1200, y: 860 }], isClosed: false }, text: 'Connect the ends', ink: 'green', isFilled: false },
      {
        shape: { kind: 'path', points: [{ x: 600, y: 808 }, { x: 652, y: 808 }, { x: 652, y: 860 }], isClosed: false },
        text: null,
        ink: 'white',
        isFilled: false,
      },
    ],
  };
}

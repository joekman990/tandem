// Threadbear patch: Tandem's tools in any Threadbear thread working on a
// video, wherever the video's folder is. `appliesTo` makes it a tool patch,
// so Threadbear finds it here in Tandem's repo and applies it to a thread
// whose folder (or a parent of it) holds a .tandem project, running in that
// folder. See docs/protocol.md "Patches" in mikecann/threadbear.
//
// - The Tandem panel on the rail: Mike's comments waiting for the agent,
//   the handback still to watch and the edits waiting for his review, with
//   the review count as its badge.
// - "Your turn" turns up once Mike has left comments on the timeline, with
//   how many, and sends the agent off to do them.

type Ctx = { cwd: string; matched: string[]; sh: (command: string) => Promise<string> };

type Comment = { id: string; time: number; text: string };
type LookHere = { start: number; name: string; note?: string; question?: boolean };
type Review = { label: string; date: string };
type Project = { name: string; path: string; comments: Comment[]; handback: LookHere[]; reviews: Review[] };

const quote = (s: string) => `'${s.replaceAll("'", `'\\''`)}'`;

// Every .tandem project in the folder, read with --project so a folder with
// two (a long cut and a short) works. Threadbear runs a command once per
// read however many functions ask, so these are cheap to call from each.
async function projects({ matched, sh }: Ctx): Promise<Project[]> {
  return Promise.all(
    matched.map(async (file) => {
      const flag = `--project ${quote(file)}`;
      const [status, comments] = await Promise.all([sh(`tandem status --json ${flag}`), sh(`tandem comments --json ${flag}`)]);
      const s = JSON.parse(status);
      return {
        name: s.name ?? file.split('/').pop()!.replace(/\.tandem$/, ''),
        path: file,
        comments: JSON.parse(comments).comments ?? [],
        handback: s.handback ?? [],
        reviews: s.reviewPending ?? [],
      };
    }),
  );
}

const sum = (list: Project[], key: 'comments' | 'handback' | 'reviews') => list.reduce((n, p) => n + p[key].length, 0);

// 125.4 -> "2:05".
function clock(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}

export default {
  appliesTo: '*.tandem',
  // On each chip, so Tandem's read as Tandem's next to the repo's own.
  icon: 'film',
  actions: [
    {
      title: 'Your turn',
      prompt:
        "I've left comments on the timeline in Tandem. Read them with `tandem comments`, do what each one asks and resolve it, then `tandem check` and hand back with `tandem handback`.",
      note: 'Shows when there are comments on the timeline for the agent',
      when: async (ctx: Ctx) => sum(await projects(ctx), 'comments') > 0,
      badge: async (ctx: Ctx) => sum(await projects(ctx), 'comments'),
    },
    { title: 'Open in Tandem', run: 'open *.tandem', note: 'Opens the video in Tandem' },
  ],
  panels: [
    {
      title: 'Tandem',
      icon: 'film',
      note: 'Comments, handback and edits waiting for review',
      badge: async (ctx: Ctx) => sum(await projects(ctx), 'reviews'),
      items: async (ctx: Ctx) => {
        const list = await projects(ctx);
        const rows: Record<string, unknown>[] = [];
        for (const p of list) {
          // A heading per project only when there's more than one.
          if (list.length > 1) rows.push({ title: p.name, path: p.path, icon: 'film' });
          for (const c of p.comments) rows.push({ title: c.text, detail: `Comment at ${clock(c.time)}, for the agent`, icon: 'text.bubble', tone: 'attention' });
          for (const h of p.handback) rows.push({ title: h.name, detail: `${h.question ? 'Question' : 'Look here'} at ${clock(h.start)}${h.note ? `: ${h.note}` : ''}`, icon: h.question ? 'questionmark.bubble' : 'eye' });
          for (const r of p.reviews) rows.push({ title: r.label, detail: 'Waiting for your review', icon: 'checkmark.circle' });
          if (!p.comments.length && !p.handback.length && !p.reviews.length) rows.push({ title: list.length > 1 ? 'Nothing waiting' : `${p.name}: nothing waiting`, tone: 'done' });
        }
        return rows;
      },
    },
  ],
};

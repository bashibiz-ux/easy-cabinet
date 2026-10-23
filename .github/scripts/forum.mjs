// Writes docs/forum.json: the discussions of this repository with their replies, for the Forum window of Easy Cabinet (the extension reads it from the Pages site).
// Run by .github/workflows/forum.yml with the token GitHub gives the job (it only reads the discussions of this repository).
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const QUERY = `query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    url
    discussions(first: 30, orderBy: { field: CREATED_AT, direction: DESC }) {
      nodes {
        title url createdAt bodyText
        author { login avatarUrl(size: 80) }
        category { name }
        comments(first: 50) {
          nodes {
            bodyText createdAt author { login avatarUrl(size: 80) }
            replies(first: 20) { nodes { bodyText createdAt author { login avatarUrl(size: 80) } } }
          }
        }
      }
    }
  }
}`;

const day = (iso) => String(iso || '').slice(0, 10);
const person = (post) => ({ author: (post.author && post.author.login) || 'ghost', avatar: (post.author && post.author.avatarUrl) || '' });

// A comment and the replies written under it, as one list in the order they were written.
function replies(comments) {
  const all = [];
  (comments || []).forEach((comment) => {
    all.push(comment);
    ((comment.replies && comment.replies.nodes) || []).forEach((reply) => all.push(reply));
  });
  return all
    .sort((a, b) => String(a.createdAt).localeCompare(String(b.createdAt)))
    .map((post) => ({ ...person(post), date: day(post.createdAt), body: String(post.bodyText || '').trim() }))
    .filter((reply) => reply.body);
}

export function build(repoUrl, discussions) {
  return {
    new_url: `${repoUrl}/discussions/new/choose`,
    topics: (discussions || []).map((topic) => {
      const comments = replies(topic.comments && topic.comments.nodes);
      return {
        title: topic.title, ...person(topic), date: day(topic.createdAt), url: topic.url,
        tags: topic.category ? [topic.category.name] : [], body: String(topic.bodyText || '').trim(), replies: comments.length, comments
      };
    })
  };
}

async function main() {
  const [owner, name] = process.env.GITHUB_REPOSITORY.split('/');
  const response = await fetch('https://api.github.com/graphql', {
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.GITHUB_TOKEN}`, 'Content-Type': 'application/json', 'User-Agent': 'easy-cabinet-forum' },
    body: JSON.stringify({ query: QUERY, variables: { owner, name } })
  });
  const answer = await response.json();
  if (!response.ok || answer.errors) throw new Error(`GitHub answered ${response.status}: ${JSON.stringify(answer.errors || answer)}`);
  const repository = answer.data.repository;
  const text = `${JSON.stringify(build(repository.url, repository.discussions.nodes), null, 2)}\n`;
  const file = 'docs/forum.json';
  if (existsSync(file) && readFileSync(file, 'utf8') === text) { console.log('The forum file is up to date.'); return; }
  writeFileSync(file, text);
  console.log(`Wrote ${file}.`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main().catch((error) => { console.error(error); process.exit(1); });

# One format for extension output and agent replies? (GPT-6 Astra, 2026-11-08)

Owner's question: extensions answer in JSON, agents in markup; both land in the same panel. Are they the same thing?

**Verdict: keep the two authoring formats, keep the shared model underneath.** Extension JSON is a command protocol (results, navigation, actions, errors, `close` and `reload`); markup is a document language (prose interleaved with components). They already share the parser, the component catalog, `Document`, `Item`, `Screen` and `ScreenContext`: `detail.markdown` and `list.summary` are markup, and a rows-only document becomes a filterable list. The differences have reasons:

- **Structure versus prose:** JSON lists carry stable ids, arbitrary actions and predictable filtering; markup interleaves explanation and components.
- **Strictness** is already a validation policy, not a language: agent markup is rendered tolerantly, `wicket run` fails extension markup on any problem.
- **Authority** is enforced by `ActionPolicy` whatever the syntax: extensions run their own revision-bound commands; agent content only presents.
- **Lifecycle:** one response per extension run versus whole agent messages.

| Option | Gains | Costs |
|---|---|---|
| Keep today's formats | Coherent tooling and prompts | Some concepts have two spellings |
| Extensions return markup only | One presentation language | Ids, action bindings, effects and args need control tags; high risk |
| Agents return extension JSON | Strict decoding | Escaped prose, worse replies, still two formats |
| Shared model, two syntaxes | Mostly exists already | A full JSON twin per component would be a second catalog |

**Next step:** documentation only, a paired example (a file list as JSON and as markup, and why "Mark Done" needs the JSON envelope). No migration.

**On extensions doing more,** once scope allows, in order:
1. **Choices and deliberate submission.** Extensions already have them (items with `run` actions and `args`, live commands for text); document the patterns. For agents, the planned choice component sends its text as a Follow Up, never a command or an approval.
2. **Small forms** (text and single choice, explicit Submit): an extension gets structured values in its own command; an agent gets a readable Follow Up.
3. **Foreground progress:** status events followed by one result, with cancellation; a transport change, not document syntax.

Deliberately deferred: background workers, scheduling, callbacks, notification subscriptions; protocol 2 just removed that lifecycle complexity.

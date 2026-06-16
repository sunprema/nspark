<script>
  import { onMount } from "svelte";
  import { EditorView, keymap, Decoration, MatchDecorator, ViewPlugin } from "@codemirror/view";
  import { EditorState } from "@codemirror/state";
  import { history, historyKeymap, defaultKeymap } from "@codemirror/commands";
  import { syntaxHighlighting, defaultHighlightStyle } from "@codemirror/language";
  import { markdown } from "@codemirror/lang-markdown";
  import { autocompletion, completionKeymap } from "@codemirror/autocomplete";

  let { node_id, content = "", variables = [], live } = $props();

  let el;
  let view;
  // Tracks which node the editor currently holds, so we only swap the document
  // when the selection actually changes (not on our own keystrokes). Set in
  // onMount to avoid capturing only the initial prop value.
  let currentId;

  // Highlight {variable} tokens.
  const varMatcher = new MatchDecorator({
    regexp: /\{[a-zA-Z_]\w*\}/g,
    decoration: Decoration.mark({ class: "cm-variable-token" }),
  });
  const variablePlugin = ViewPlugin.fromClass(
    class {
      decorations;
      constructor(v) {
        this.decorations = varMatcher.createDeco(v);
      }
      update(u) {
        this.decorations = varMatcher.updateDeco(u, this.decorations);
      }
    },
    { decorations: (v) => v.decorations },
  );

  // Autocomplete {variables} discovered across the graph.
  function variableCompletions(context) {
    const token = context.matchBefore(/\{[\w]*/);
    if (!token) return null;
    if (token.from === token.to && !context.explicit) return null;
    return {
      from: token.from,
      options: variables.map((v) => ({
        label: `{${v}}`,
        type: "variable",
        apply: `{${v}}`,
      })),
    };
  }

  let debounce;
  function onUpdate(u) {
    if (!u.docChanged) return;
    clearTimeout(debounce);
    const text = u.state.doc.toString();
    debounce = setTimeout(() => {
      if (currentId) live?.pushEvent("update_node_content", { id: currentId, content: text });
    }, 500);
  }

  const theme = EditorView.theme({
    "&": {
      fontSize: "12px",
      backgroundColor: "oklch(0.99 0.004 245)",
      border: "1px solid oklch(0.82 0.02 250)",
      color: "oklch(0.34 0.02 255)",
    },
    "&.cm-focused": { outline: "none", borderColor: "oklch(0.7 0.06 255)" },
    ".cm-content": {
      fontFamily: "'IBM Plex Mono', monospace",
      lineHeight: "1.6",
      padding: "10px 11px",
    },
    ".cm-variable-token": {
      backgroundColor: "oklch(0.94 0.02 255)",
      color: "oklch(0.45 0.1 255)",
      borderRadius: "2px",
      padding: "0 2px",
    },
  });

  onMount(() => {
    view = new EditorView({
      state: EditorState.create({
        doc: content,
        extensions: [
          history(),
          keymap.of([...defaultKeymap, ...historyKeymap, ...completionKeymap]),
          markdown(),
          syntaxHighlighting(defaultHighlightStyle),
          EditorView.lineWrapping,
          variablePlugin,
          autocompletion({ override: [variableCompletions] }),
          theme,
          EditorView.updateListener.of(onUpdate),
        ],
      }),
      parent: el,
    });
    currentId = node_id;

    return () => view?.destroy();
  });

  // Swap the document when a different node is selected.
  $effect(() => {
    if (view && node_id !== currentId) {
      currentId = node_id;
      clearTimeout(debounce);
      view.dispatch({
        changes: { from: 0, to: view.state.doc.length, insert: content },
      });
    }
  });
</script>

<div class="cm-host" bind:this={el}></div>

<style>
  .cm-host {
    display: block;
  }
</style>

/// Anki note-type definition for exported SecurePlayer MCQ questions.
///
/// Ported from `D:\Projects\Anki generator\card_models.py` (Data62Team_MCQ
/// model) — the HTML/CSS/JS is language-agnostic (it executes inside Anki's
/// own WebView regardless of what wrote the .apkg), so it's carried over
/// nearly verbatim: the 5-theme CSS-variable switcher, the clickable-choice
/// JS reading a hidden ChoicesJSON field, the settings-gear panel with
/// independent Question/Explanation RTL toggles, the 700ms auto-flip.
/// Net-new here: an `Image` field + conditional `{{#Image}}` block — the
/// reference generator has no image support at all.
library;

/// Field order matches the index used when building each note's `flds`
/// string (see anki_package_builder.dart) — must stay in sync.
const List<String> ankiNoteFields = [
  'Question',
  'ChoicesJSON',
  'CorrectKey',
  'Explanation',
  'Image',
  'Source',
  'QuestionDir',
  'ExplanationDir',
];

const String _sharedCss = r'''
/* ═══════════════════════════════════════════════════════
   SecurePlayer — Shared Card Styles + Theme Engine
   (ported from Anki generator's Data62Team card templates)
   ═══════════════════════════════════════════════════════ */

:root,
[data-theme="indigo"] {
  --bg:          #0f0f1a;
  --surface:     #1a1a2e;
  --surface2:    #16213e;
  --border:      rgba(99,102,241,0.25);
  --accent:      #6366f1;
  --accent-glow: rgba(99,102,241,0.35);
  --text:        #e2e8f0;
  --text-muted:  #94a3b8;
  --correct:     #22c55e;
  --wrong:       #ef4444;
  --correct-bg:  rgba(34,197,94,0.15);
  --wrong-bg:    rgba(239,68,68,0.15);
  --btn-bg:      rgba(255,255,255,0.05);
  --btn-hover:   rgba(99,102,241,0.2);
  --hr-color:    rgba(99,102,241,0.4);
  --brand-color: #94a3b8;
}

[data-theme="ocean"] {
  --bg:          #060d1a;
  --surface:     #0d1f3c;
  --surface2:    #0a1628;
  --border:      rgba(56,189,248,0.25);
  --accent:      #38bdf8;
  --accent-glow: rgba(56,189,248,0.35);
  --text:        #e0f2fe;
  --text-muted:  #7dd3fc;
  --correct:     #4ade80;
  --wrong:       #f87171;
  --correct-bg:  rgba(74,222,128,0.15);
  --wrong-bg:    rgba(248,113,113,0.15);
  --btn-bg:      rgba(255,255,255,0.05);
  --btn-hover:   rgba(56,189,248,0.2);
  --hr-color:    rgba(56,189,248,0.4);
  --brand-color: #7dd3fc;
}

[data-theme="forest"] {
  --bg:          #051a0e;
  --surface:     #0d2b18;
  --surface2:    #0a2214;
  --border:      rgba(52,211,153,0.25);
  --accent:      #34d399;
  --accent-glow: rgba(52,211,153,0.35);
  --text:        #d1fae5;
  --text-muted:  #6ee7b7;
  --correct:     #4ade80;
  --wrong:       #f87171;
  --correct-bg:  rgba(74,222,128,0.15);
  --wrong-bg:    rgba(248,113,113,0.15);
  --btn-bg:      rgba(255,255,255,0.05);
  --btn-hover:   rgba(52,211,153,0.2);
  --hr-color:    rgba(52,211,153,0.4);
  --brand-color: #6ee7b7;
}

[data-theme="amber"] {
  --bg:          #1a1000;
  --surface:     #2d1c00;
  --surface2:    #231500;
  --border:      rgba(251,191,36,0.25);
  --accent:      #fbbf24;
  --accent-glow: rgba(251,191,36,0.35);
  --text:        #fef3c7;
  --text-muted:  #fcd34d;
  --correct:     #4ade80;
  --wrong:       #f87171;
  --correct-bg:  rgba(74,222,128,0.15);
  --wrong-bg:    rgba(248,113,113,0.15);
  --btn-bg:      rgba(255,255,255,0.05);
  --btn-hover:   rgba(251,191,36,0.2);
  --hr-color:    rgba(251,191,36,0.4);
  --brand-color: #fcd34d;
}

[data-theme="rose"] {
  --bg:          #1a0510;
  --surface:     #2d0d1e;
  --surface2:    #230916;
  --border:      rgba(244,114,182,0.25);
  --accent:      #f472b6;
  --accent-glow: rgba(244,114,182,0.35);
  --text:        #fce7f3;
  --text-muted:  #f9a8d4;
  --correct:     #4ade80;
  --wrong:       #f87171;
  --correct-bg:  rgba(74,222,128,0.15);
  --wrong-bg:    rgba(248,113,113,0.15);
  --btn-bg:      rgba(255,255,255,0.05);
  --btn-hover:   rgba(244,114,182,0.2);
  --hr-color:    rgba(244,114,182,0.4);
  --brand-color: #f9a8d4;
}

*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

body, .card {
  background: var(--bg) !important;
  color: var(--text) !important;
  font-family: 'Segoe UI', 'Helvetica Neue', Arial, sans-serif !important;
  min-height: 100vh;
  padding: 0 !important;
}

.d62-card {
  position: relative;
  min-height: 100vh;
  background: var(--bg);
  display: flex;
  flex-direction: column;
  align-items: stretch;
  padding: 20px 18px 60px;
  transition: background 0.3s ease;
}

.d62-topbar {
  display: flex;
  justify-content: flex-end;
  margin-bottom: 12px;
}

.d62-settings-btn {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 8px;
  color: var(--text-muted);
  cursor: pointer;
  padding: 6px 10px;
  font-size: 16px;
  line-height: 1;
  transition: all 0.2s;
}
.d62-settings-btn:hover { color: var(--accent); border-color: var(--accent); }

.d62-theme-panel {
  display: none;
  position: absolute;
  top: 50px;
  right: 18px;
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 12px;
  padding: 12px;
  z-index: 100;
  box-shadow: 0 8px 32px rgba(0,0,0,0.5);
  min-width: 190px;
}
.d62-theme-panel.open { display: block; }

.d62-theme-label {
  font-size: 0.7rem;
  color: var(--text-muted);
  text-transform: uppercase;
  letter-spacing: 1px;
  margin-bottom: 8px;
  display: block;
}

.d62-theme-grid {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 6px;
}

.d62-theme-chip {
  border: 1.5px solid transparent;
  border-radius: 8px;
  cursor: pointer;
  padding: 7px 10px;
  font-size: 0.75rem;
  font-weight: 600;
  text-align: center;
  transition: all 0.2s;
  background: rgba(255,255,255,0.05);
  color: var(--text);
}
.d62-theme-chip:hover, .d62-theme-chip.active { border-color: var(--accent); background: var(--btn-hover); }

.d62-question {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 14px;
  padding: 18px 20px;
  font-size: 1.05rem;
  line-height: 1.65;
  color: var(--text);
  margin-bottom: 18px;
  white-space: pre-wrap;
  word-break: break-word;
}

.d62-image {
  margin-bottom: 18px;
  text-align: center;
}
.d62-image img {
  max-width: 100%;
  max-height: 320px;
  border-radius: 10px;
  border: 1px solid var(--border);
}

.d62-source {
  font-size: 0.68rem;
  color: var(--text-muted);
  margin-bottom: 14px;
  text-align: right;
  letter-spacing: 0.3px;
}

.d62-choices {
  display: flex;
  flex-direction: column;
  gap: 6px;
}

.d62-choice {
  background: var(--btn-bg);
  border: 1.5px solid var(--border);
  border-radius: 12px;
  color: var(--text);
  cursor: pointer;
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 13px 16px;
  font-size: 0.95rem;
  line-height: 1.5;
  text-align: start;
  transition: background 0.18s, border-color 0.18s, transform 0.1s, box-shadow 0.18s;
  width: 100%;
  word-break: break-word;
}
.d62-choice:hover:not(:disabled) {
  background: var(--btn-hover);
  border-color: var(--accent);
  box-shadow: 0 0 12px var(--accent-glow);
  transform: translateX(2px);
}
.d62-choice:disabled { cursor: default; }

.d62-choice-key {
  background: var(--surface2);
  border-radius: 6px;
  color: var(--accent);
  font-size: 0.8rem;
  font-weight: 700;
  min-width: 28px;
  padding: 3px 7px;
  text-align: center;
  flex-shrink: 0;
  transition: background 0.18s, color 0.18s;
}

.d62-choice.correct {
  background: var(--correct-bg) !important;
  border-color: var(--correct) !important;
  box-shadow: 0 0 16px rgba(34,197,94,0.3) !important;
}
.d62-choice.correct .d62-choice-key {
  background: var(--correct);
  color: #fff;
}

.d62-choice.wrong {
  background: var(--wrong-bg) !important;
  border-color: var(--wrong) !important;
  box-shadow: 0 0 16px rgba(239,68,68,0.25) !important;
}
.d62-choice.wrong .d62-choice-key {
  background: var(--wrong);
  color: #fff;
}

.d62-choice-icon {
  margin-inline-start: auto;
  font-size: 1.1rem;
  flex-shrink: 0;
  opacity: 0;
  transition: opacity 0.2s;
}
.d62-choice.correct .d62-choice-icon,
.d62-choice.wrong   .d62-choice-icon { opacity: 1; }

.d62-sep {
  border: none;
  border-top: 1.5px solid var(--hr-color);
  margin: 22px 0;
  width: 100%;
}

.d62-explanation-label {
  font-size: 0.7rem;
  text-transform: uppercase;
  letter-spacing: 1.2px;
  color: var(--text-muted);
  font-weight: 700;
  margin-bottom: 8px;
}

.d62-explanation {
  background: var(--surface2);
  border: 1px solid var(--border);
  border-radius: 14px;
  padding: 16px 20px;
  font-size: 0.92rem;
  line-height: 1.8;
  color: var(--text);
  white-space: pre-wrap;
  word-break: break-word;
}
.d62-explanation strong, .d62-explanation b { color: var(--accent); }

.d62-dir-row {
  display: flex;
  align-items: center;
  gap: 6px;
  margin-top: 10px;
}
.d62-dir-label {
  font-size: 0.68rem;
  color: var(--text-muted);
  flex: 1;
  text-transform: uppercase;
  letter-spacing: 0.8px;
}
.d62-dir-btn {
  background: var(--btn-bg);
  border: 1.5px solid var(--border);
  border-radius: 6px;
  color: var(--text-muted);
  cursor: pointer;
  font-size: 0.72rem;
  font-weight: 700;
  padding: 4px 9px;
  transition: all 0.18s;
  letter-spacing: 0.5px;
}
.d62-dir-btn:hover { color: var(--accent); border-color: var(--accent); }
.d62-dir-btn.active {
  background: var(--btn-hover);
  border-color: var(--accent);
  color: var(--accent);
}

.d62-brand {
  position: fixed;
  bottom: 14px;
  right: 16px;
  border: 1px solid var(--brand-color);
  border-radius: 7px;
  color: var(--brand-color);
  font-size: 0.6rem;
  font-weight: 600;
  letter-spacing: 1px;
  opacity: 0.55;
  padding: 4px 8px;
  pointer-events: none;
  text-transform: uppercase;
  transition: opacity 0.2s;
}

.d62-correct-announce {
  background: var(--correct-bg);
  border: 1px solid var(--correct);
  border-radius: 10px;
  color: var(--correct);
  font-size: 0.88rem;
  font-weight: 600;
  margin-bottom: 14px;
  padding: 10px 14px;
  text-align: center;
}
''';

const String _themeJs = r'''
<script>
(function() {
  var THEME_KEY   = 'sp_theme';
  var Q_DIR_KEY   = 'sp_q_dir';     // 'ltr' | 'rtl'
  var EXP_DIR_KEY = 'sp_exp_dir';   // 'ltr' | 'rtl'

  var THEMES = [
    { id: 'indigo', label: '\u{1F7E3} Indigo' },
    { id: 'ocean',  label: '\u{1F535} Ocean'  },
    { id: 'forest', label: '\u{1F7E2} Forest' },
    { id: 'amber',  label: '\u{1F7E1} Amber'  },
    { id: 'rose',   label: '\u{1F497} Rose'   }
  ];

  function getTheme() {
    try { return localStorage.getItem(THEME_KEY) || 'indigo'; } catch(e) { return 'indigo'; }
  }
  function setTheme(t) {
    try { localStorage.setItem(THEME_KEY, t); } catch(e) {}
    document.documentElement.setAttribute('data-theme', t);
    document.body.setAttribute('data-theme', t);
    var card = document.querySelector('.d62-card');
    if (card) card.setAttribute('data-theme', t);
    document.querySelectorAll('.d62-theme-chip').forEach(function(c) {
      c.classList.toggle('active', c.dataset.theme === t);
    });
  }

  function getDir(key, def) {
    try { return localStorage.getItem(key) || def; } catch(e) { return def; }
  }
  function applyDir(selector, dir) {
    document.querySelectorAll(selector).forEach(function(el) {
      el.style.direction  = dir;
      el.style.textAlign  = (dir === 'rtl') ? 'right' : 'left';
    });
  }
  function setDir(key, selector, dir, btnGroup) {
    try { localStorage.setItem(key, dir); } catch(e) {}
    applyDir(selector, dir);
    if (btnGroup) {
      btnGroup.querySelectorAll('.d62-dir-btn').forEach(function(b) {
        b.classList.toggle('active', b.dataset.dir === dir);
      });
    }
  }

  function buildPanel() {
    var btn   = document.getElementById('d62-settings-btn');
    var panel = document.getElementById('d62-theme-panel');
    if (!btn || !panel) return;

    var grid = panel.querySelector('.d62-theme-grid');
    THEMES.forEach(function(th) {
      var chip = document.createElement('button');
      chip.className    = 'd62-theme-chip';
      chip.dataset.theme = th.id;
      chip.textContent  = th.label;
      chip.onclick = function() { setTheme(th.id); };
      grid.appendChild(chip);
    });

    // Per-note direction is baked into the card via the QuestionDir/
    // ExplanationDir fields (see anki_package_builder.dart) and already
    // applied through the dir="{{...}}" attributes in the templates below —
    // these hidden spans are only read here to seed the *toggle's* displayed
    // default, so it reflects this note's real configured direction instead
    // of a hardcoded literal the first time the panel opens.
    var qMeta   = document.getElementById('d62-meta-qdir');
    var expMeta = document.getElementById('d62-meta-expdir');
    var qNoteDefault   = (qMeta && qMeta.textContent)   || 'rtl';
    var expNoteDefault = (expMeta && expMeta.textContent) || 'rtl';

    var dirRows = [
      { key: Q_DIR_KEY,   sel: '.d62-question, .d62-choices', def: qNoteDefault,   label: 'Question' },
      { key: EXP_DIR_KEY, sel: '.d62-explanation',            def: expNoteDefault, label: 'Explanation' }
    ];
    dirRows.forEach(function(cfg) {
      var row = document.createElement('div');
      row.className = 'd62-dir-row';

      var lbl = document.createElement('span');
      lbl.className   = 'd62-dir-label';
      lbl.textContent = cfg.label;
      row.appendChild(lbl);

      ['ltr', 'rtl'].forEach(function(d) {
        var b = document.createElement('button');
        b.className      = 'd62-dir-btn';
        b.dataset.dir    = d;
        b.textContent    = d.toUpperCase();
        b.onclick = function(e) {
          e.stopPropagation();
          setDir(cfg.key, cfg.sel, d, row);
        };
        row.appendChild(b);
      });

      panel.appendChild(row);

      var saved = getDir(cfg.key, cfg.def);
      setDir(cfg.key, cfg.sel, saved, row);
    });

    btn.onclick = function(e) {
      e.stopPropagation();
      panel.classList.toggle('open');
    };
    document.addEventListener('click', function() {
      panel.classList.remove('open');
    });
  }

  function init() {
    setTheme(getTheme());
    buildPanel();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
</script>
''';

const String _topbarHtml = r'''
<div class="d62-topbar">
  <button class="d62-settings-btn" id="d62-settings-btn" title="Settings">&#9881;&#65039;</button>
  <div class="d62-theme-panel" id="d62-theme-panel">
    <span class="d62-theme-label">Theme</span>
    <div class="d62-theme-grid"></div>
  </div>
</div>
''';

const String _brandHtml = '<div class="d62-brand">SecurePlayer</div>';

/// Front template: question (+ optional image) + clickable MCQ choices.
const String ankiMcqFrontTemplate =
    '<style>$_sharedCss</style>\n'
    '<div class="d62-card" id="d62-card-front">\n'
    '  $_topbarHtml\n'
    '  <div class="d62-source">{{Source}}</div>\n'
    '  {{#Image}}<div class="d62-image"><img src="{{Image}}"></div>{{/Image}}\n'
    '  <div class="d62-question" dir="{{QuestionDir}}">{{Question}}</div>\n'
    '  <div class="d62-choices" id="d62-choices" dir="{{QuestionDir}}"></div>\n'
    '</div>\n'
    '$_brandHtml\n'
    '<script>\n'
    '(function() {\n'
    '  var raw = document.getElementById(\'d62-choices-data\');\n'
    '  var correctKey = (document.getElementById(\'d62-correct-key\') || {}).textContent || \'\';\n'
    '  if (!raw) return;\n'
    '  var data;\n'
    '  try { data = JSON.parse(raw.textContent || raw.innerText); } catch(e) { return; }\n'
    '  var container = document.getElementById(\'d62-choices\');\n'
    '  var keys = Object.keys(data);\n'
    '  keys.forEach(function(key) {\n'
    '    var btn = document.createElement(\'button\');\n'
    '    btn.className = \'d62-choice\';\n'
    '    btn.innerHTML =\n'
    '      \'<span class="d62-choice-key">\' + key + \'</span>\' +\n'
    '      \'<span class="d62-choice-text">\' + data[key] + \'</span>\' +\n'
    '      \'<span class="d62-choice-icon"></span>\';\n'
    '    btn.onclick = function() { handleChoice(key, btn, keys, data, correctKey); };\n'
    '    container.appendChild(btn);\n'
    '  });\n'
    '  function handleChoice(selected, clickedBtn, keys, data, correct) {\n'
    '    container.querySelectorAll(\'.d62-choice\').forEach(function(b) {\n'
    '      b.disabled = true;\n'
    '    });\n'
    '    container.querySelectorAll(\'.d62-choice\').forEach(function(b, i) {\n'
    '      var k = keys[i];\n'
    '      var icon = b.querySelector(\'.d62-choice-icon\');\n'
    '      if (k === correct) {\n'
    '        b.classList.add(\'correct\');\n'
    '        if (icon) icon.textContent = \'✅\';\n'
    '      } else if (k === selected && k !== correct) {\n'
    '        b.classList.add(\'wrong\');\n'
    '        if (icon) icon.textContent = \'❌\';\n'
    '      }\n'
    '    });\n'
    '    setTimeout(function() {\n'
    '      if (typeof AnkiDroidJS !== \'undefined\') {\n'
    '        AnkiDroidJS.showAnswer();\n'
    '      } else {\n'
    '        var sa = document.getElementById(\'typeans\') ||\n'
    '                 document.querySelector(\'.bottom\') ||\n'
    '                 document.querySelector(\'[id*="answer"]\') ||\n'
    '                 document.querySelector(\'a[onclick*="pycmd"]\');\n'
    '        if (!sa) {\n'
    '          var evt = new KeyboardEvent(\'keydown\', {keyCode: 32, which: 32, bubbles: true});\n'
    '          document.dispatchEvent(evt);\n'
    '        } else {\n'
    '          sa.click();\n'
    '        }\n'
    '      }\n'
    '    }, 700);\n'
    '  }\n'
    '})();\n'
    '</script>\n'
    '<span id="d62-choices-data" style="display:none">{{ChoicesJSON}}</span>\n'
    '<span id="d62-correct-key"  style="display:none">{{CorrectKey}}</span>\n'
    '<span id="d62-meta-qdir"    style="display:none">{{QuestionDir}}</span>\n'
    '<span id="d62-meta-expdir"  style="display:none">{{ExplanationDir}}</span>\n'
    '$_themeJs';

/// Back template: question (+ image) + correct-answer announcement + explanation.
const String ankiMcqBackTemplate =
    '<style>$_sharedCss</style>\n'
    '<div class="d62-card" id="d62-card-back">\n'
    '  $_topbarHtml\n'
    '  <div class="d62-source">{{Source}}</div>\n'
    '  {{#Image}}<div class="d62-image"><img src="{{Image}}"></div>{{/Image}}\n'
    '  <div class="d62-question" dir="{{QuestionDir}}">{{Question}}</div>\n'
    '  <div class="d62-correct-announce">\n'
    '    ✅ الإجابة الصحيحة: <strong id="d62-back-correct"></strong>\n'
    '  </div>\n'
    '  <hr class="d62-sep">\n'
    '  <div class="d62-explanation-label">الشرح</div>\n'
    '  <div class="d62-explanation" id="d62-expl" dir="{{ExplanationDir}}">{{Explanation}}</div>\n'
    '</div>\n'
    '$_brandHtml\n'
    '<script>\n'
    '(function() {\n'
    '  var raw = document.getElementById(\'d62-choices-data-back\');\n'
    '  var correctKey = (document.getElementById(\'d62-correct-key-back\') || {}).textContent || \'\';\n'
    '  if (raw && correctKey) {\n'
    '    try {\n'
    '      var data = JSON.parse(raw.textContent || raw.innerText);\n'
    '      var el = document.getElementById(\'d62-back-correct\');\n'
    '      if (el) el.textContent = correctKey + \') \' + (data[correctKey] || \'\');\n'
    '    } catch(e) {}\n'
    '  }\n'
    '  var expl = document.getElementById(\'d62-expl\');\n'
    '  if (expl) {\n'
    '    var html = expl.innerHTML;\n'
    '    html = html.replace(/\\*\\*([^*]+)\\*\\*/g, \'<strong>\$1</strong>\');\n'
    '    html = html.replace(/\\*([^*]+)\\*/g,   \'<em>\$1</em>\');\n'
    '    expl.innerHTML = html;\n'
    '  }\n'
    '})();\n'
    '</script>\n'
    '<span id="d62-choices-data-back" style="display:none">{{ChoicesJSON}}</span>\n'
    '<span id="d62-correct-key-back"  style="display:none">{{CorrectKey}}</span>\n'
    '<span id="d62-meta-qdir"         style="display:none">{{QuestionDir}}</span>\n'
    '<span id="d62-meta-expdir"       style="display:none">{{ExplanationDir}}</span>\n'
    '$_themeJs';

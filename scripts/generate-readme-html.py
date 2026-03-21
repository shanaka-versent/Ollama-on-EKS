#!/usr/bin/env python3
"""
Convert README.md to a styled HTML file with Mermaid diagram support.
Matches the visual style of Ollama-EKS-Report.html.
"""

import markdown
import re
import sys
from pathlib import Path

def convert_readme_to_html(readme_path, output_path):
    md_content = Path(readme_path).read_text()

    # Extract mermaid blocks before markdown processing
    mermaid_blocks = {}
    mermaid_counter = [0]

    def replace_mermaid(match):
        mermaid_counter[0] += 1
        key = f"MERMAID_PLACEHOLDER_{mermaid_counter[0]}"
        mermaid_blocks[key] = match.group(1)
        return f'<div class="mermaid">{key}</div>'

    md_content = re.sub(r'```mermaid\n(.*?)```', replace_mermaid, md_content, flags=re.DOTALL)

    # Convert markdown to HTML
    html_body = markdown.markdown(
        md_content,
        extensions=['tables', 'fenced_code', 'codehilite', 'toc', 'attr_list'],
        extension_configs={
            'codehilite': {'css_class': 'highlight', 'guess_lang': False},
            'toc': {'title': 'Table of Contents'}
        }
    )

    # Restore mermaid blocks
    for key, diagram in mermaid_blocks.items():
        html_body = html_body.replace(key, diagram)

    # Build full HTML document
    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Ollama on EKS — README</title>
<script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
<script>
  document.addEventListener('DOMContentLoaded', function() {{
    mermaid.initialize({{
      startOnLoad: true,
      theme: 'default',
      securityLevel: 'loose',
      sequence: {{ diagramMarginX: 20, diagramMarginY: 10, actorMargin: 60, width: 180, height: 50 }},
      flowchart: {{ htmlLabels: true, curve: 'basis' }},
      gantt: {{ leftPadding: 160 }}
    }});
  }});
</script>
<style>
  :root {{
    --bg: #ffffff;
    --text: #1a1a2e;
    --text-secondary: #555;
    --accent: #5C4EE5;
    --accent-light: #E8E6FF;
    --border: #e0e0e0;
    --code-bg: #f6f8fa;
    --table-header: #f0f0f5;
    --table-stripe: #fafafa;
    --success: #2E8B57;
    --warning: #FF9900;
    --card-shadow: 0 2px 8px rgba(0,0,0,0.08);
  }}

  * {{ box-sizing: border-box; margin: 0; padding: 0; }}

  body {{
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', 'Inter', Roboto, Helvetica, Arial, sans-serif;
    line-height: 1.7;
    color: var(--text);
    background: var(--bg);
    max-width: 960px;
    margin: 0 auto;
    padding: 40px 24px;
  }}

  /* Header / Title */
  h1 {{
    font-size: 2.4em;
    font-weight: 700;
    color: var(--accent);
    margin-bottom: 12px;
    padding-bottom: 12px;
    border-bottom: 3px solid var(--accent);
  }}

  h2 {{
    font-size: 1.6em;
    font-weight: 600;
    color: var(--text);
    margin-top: 48px;
    margin-bottom: 16px;
    padding-bottom: 8px;
    border-bottom: 2px solid var(--border);
  }}

  h3 {{
    font-size: 1.25em;
    font-weight: 600;
    color: var(--text);
    margin-top: 32px;
    margin-bottom: 12px;
  }}

  h4 {{
    font-size: 1.05em;
    font-weight: 600;
    margin-top: 24px;
    margin-bottom: 8px;
  }}

  p {{
    margin-bottom: 16px;
    color: var(--text);
  }}

  a {{
    color: var(--accent);
    text-decoration: none;
  }}
  a:hover {{
    text-decoration: underline;
  }}

  hr {{
    border: none;
    border-top: 1px solid var(--border);
    margin: 40px 0;
  }}

  /* Code */
  code {{
    font-family: 'SF Mono', 'Fira Code', 'JetBrains Mono', Consolas, monospace;
    font-size: 0.88em;
    background: var(--code-bg);
    padding: 2px 6px;
    border-radius: 4px;
    color: #c7254e;
  }}

  pre {{
    background: #1e1e2e;
    color: #cdd6f4;
    border-radius: 8px;
    padding: 16px 20px;
    overflow-x: auto;
    margin-bottom: 20px;
    line-height: 1.5;
    box-shadow: var(--card-shadow);
  }}

  pre code {{
    background: none;
    color: inherit;
    padding: 0;
    font-size: 0.85em;
  }}

  /* Tables */
  table {{
    width: 100%;
    border-collapse: collapse;
    margin-bottom: 24px;
    font-size: 0.92em;
    box-shadow: var(--card-shadow);
    border-radius: 8px;
    overflow: hidden;
  }}

  thead th {{
    background: var(--table-header);
    font-weight: 600;
    text-align: left;
    padding: 12px 16px;
    border-bottom: 2px solid var(--border);
    white-space: nowrap;
  }}

  tbody td {{
    padding: 10px 16px;
    border-bottom: 1px solid var(--border);
    vertical-align: top;
  }}

  tbody tr:nth-child(even) {{
    background: var(--table-stripe);
  }}

  tbody tr:hover {{
    background: var(--accent-light);
  }}

  /* Blockquotes */
  blockquote {{
    border-left: 4px solid var(--accent);
    background: var(--accent-light);
    padding: 12px 20px;
    margin: 16px 0;
    border-radius: 0 8px 8px 0;
    color: var(--text);
  }}

  blockquote p {{
    margin-bottom: 0;
  }}

  /* Lists */
  ul, ol {{
    padding-left: 24px;
    margin-bottom: 16px;
  }}

  li {{
    margin-bottom: 6px;
  }}

  /* Mermaid diagrams */
  .mermaid {{
    background: #fafbfc;
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 20px;
    margin: 20px 0;
    text-align: center;
    overflow-x: auto;
  }}

  /* Images */
  img {{
    max-width: 100%;
    height: auto;
    border-radius: 8px;
    box-shadow: var(--card-shadow);
    margin: 16px 0;
  }}

  /* Details/Summary */
  details {{
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 12px 16px;
    margin-bottom: 12px;
    background: var(--table-stripe);
  }}

  summary {{
    cursor: pointer;
    font-weight: 600;
    color: var(--accent);
  }}

  summary:hover {{
    text-decoration: underline;
  }}

  /* Strong emphasis in tables */
  td strong, th strong {{
    color: var(--accent);
  }}

  /* Responsive */
  @media (max-width: 768px) {{
    body {{ padding: 16px; }}
    h1 {{ font-size: 1.8em; }}
    h2 {{ font-size: 1.3em; }}
    table {{ font-size: 0.82em; }}
    pre {{ padding: 12px; font-size: 0.8em; }}
  }}

  /* Print */
  @media print {{
    body {{ max-width: 100%; padding: 0; }}
    pre {{ background: #f6f8fa; color: #333; box-shadow: none; }}
    .mermaid {{ break-inside: avoid; }}
    h2 {{ break-before: page; }}
  }}

  /* Generated timestamp */
  .generated-at {{
    text-align: right;
    font-size: 0.82em;
    color: var(--text-secondary);
    margin-top: 40px;
    padding-top: 16px;
    border-top: 1px solid var(--border);
  }}
</style>
</head>
<body>
{html_body}
<div class="generated-at">
  Auto-generated from <code>README.md</code> &mdash; keep in sync using the <code>readme-sync</code> skill.
</div>
</body>
</html>"""

    Path(output_path).write_text(html)
    print(f"Generated: {output_path}")

if __name__ == "__main__":
    readme = sys.argv[1] if len(sys.argv) > 1 else "README.md"
    output = sys.argv[2] if len(sys.argv) > 2 else "README.html"
    convert_readme_to_html(readme, output)

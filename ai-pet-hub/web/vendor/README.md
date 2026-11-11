# 第三方文件

| 文件 | 来源 | 版本 | 协议 | 校验 |
|---|---|---|---|---|
| `highlight.min.js` | https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js | 11.9.0（common 语言包，37 种语言） | BSD-3-Clause | `sha512-D9gUyxqja7hBtkWpPWGt9wfbfaMGVt9gnyCvYa+jojwwPHLCzUm5i8rpk7vD7wNee9bA35eYIjobYPaQuKS1MQ==`（与 cdnjs 公布的 SRI 一致） |
| `katex/katex.min.js` | https://cdnjs.cloudflare.com/ajax/libs/KaTeX/0.19.1/katex.min.js | 0.19.1 | MIT | sha256 `fa140498b8cfc8302cbe5e7cb1bdbc1f952bc38b3fa258ede09e73edbf9a74bc` |
| `katex/katex.min.css` | 同上目录 | 0.19.1 | MIT | sha256 `00e0b094171b07f58422075f469b4feac2b2f7bce1aeec943c08da4d697f4dcf` |
| `katex/contrib/mhchem.min.js` | 同上目录（化学式 `\ce{}`） | 0.19.1 | MIT | sha256 `aaf20145c0b8ecd450ccf6eb0cebece2f77d8e6a02c30d291f28c1167b57b2df` |
| `katex/fonts/*.woff2`（20 个） | 同上目录 | 0.19.1 | MIT | 每个文件都与 npm 包 katex@0.19.1 的哈希一致 |
| `three.module.js` | three.js（npm 包 three） | r15x（见文件开头） | MIT | — |

- highlight.js：文件预览和回答里代码块的着色（`../editor.js`）；加载失败时退回 editor.js 里的轻量着色。
- KaTeX：回答和 Markdown 预览里的公式排版（`../markdown.js`）。所有文件下载后都同时核对了 cdnjs 公布的 SRI 和 npm 包里的哈希；只放了 woff2 字体，WebKit 只用这一种。

#!/usr/bin/env python3
"""极简 MCP 网页搜索服务器（仅标准库）：web_search + fetch_page，双模式。

模式一：stdio（本机子进程，默认）

    python3 websearch-mcp.py

    claude mcp add --scope user websearch -- /绝对路径/python3 /绝对路径/clients/websearch-mcp.py

    ⚠️ `--scope user` **不能省**。不写的话默认是 `local`，那条配置会被绑在
    "你运行这条命令时所在的目录"——实测换个目录工具就**凭空消失且不报错**
    （它被写进 ~/.claude.json 的 projects["<当时那个目录>"]）。`user` 才是
    这台机器上所有项目都能用。每人每台机器一次。
    ⚠️ python3 用**绝对路径**（`command -v python3` 查）。裸 `python3` 按
    Claude Code 启动时的环境解析，用 conda / venv 的同学容易踩空。

模式二：HTTP（远程共享服务，免安装）

    python3 websearch-mcp.py --http 127.0.0.1:28891 --token <TOKEN>

    客户端一行接入（Streamable HTTP 传输，MCP 2025-03-26 规范）：

    claude mcp add --scope user --transport http websearch \
      https://biotree.top:38123/websearch/mcp \
      --header "Authorization: Bearer <TOKEN>"

    团队实例部署在 bio-desktop（appnet `apps/websearch/`），TOKEN 向管理员
    获取。HTTP 模式强制开**内网地址防护**：fetch_page 拒绝解析到
    loopback / 私网 / 链路本地地址的目标，防止共享服务被当成内网跳板。

两个工具：`web_search`（搜索）+ `fetch_page`（读正文）。

为什么需要它：Claude Code 内置的 WebSearch 是**服务端工具**——由 Anthropic
的服务器执行。把 ANTHROPIC_BASE_URL 指向自建模型后，没有任何一方会去执行它
（2026-09-18 实测：内置 WebSearch 的内部调用会被网关以 400 拒掉，
`tools.N.input_schema` field required——与 Codex 0.152.0 每条请求必 400 是
同一个根因）。本工具则在**客户端侧或团队服务侧**执行，用可达的网络。

**为什么必须两个工具**（2026-09-18 协议级实测，qwen3.8-flash-next）：
只给搜索摘要（snippet）时，模型对细节类问题（版本号/日期/数据）会反复
改写查询空转 6 轮仍给不出答案；配上 fetch_page 读正文后，2 轮即答对
（vLLM 最新版本 v0.29.0，读 GitHub Releases 页）。这与 DeepSeek 网页版、
阿里百炼的官方做法同构：他们的「联网」= 搜索 API + 网页正文提取，
模型本身不上网，靠外部喂结果。

搜索源用 Bing（实测 Mac 与 DGX 都可达且能解析出结构化结果）。
DuckDuckGo 在本网络不通，故不采用。自托管 SearXNG 亦实测不可用
（引擎在本网络全军覆没，见 dgx-portal docs/clients.md §8）。
"""

from __future__ import annotations

import argparse
import hmac
import html
import http.cookiejar
import ipaddress
import json
import os
import re
import socket
import sys
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
      "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36")
HEADERS_BROWSER = {"User-Agent": UA,
                   "Accept": ("text/html,application/xhtml+xml,application/xml;"
                              "q=0.9,*/*;q=0.8"),
                   "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8"}
TIMEOUT = 20
SCHOLAR_TIMEOUT = 20
DEFAULT_COUNT = 8
DEFAULT_SCHOLAR_COUNT = 5
FETCH_CHARS = 6000
MAX_DOWNLOAD_BYTES = 2_000_000
# HTTP 模式请求体上限：MCP 的 tools/call 参数就几十字节，5MB 是宽裕安全界
MAX_RPC_BODY_BYTES = 5 * 1024 * 1024

# 2026-09-12 实测：任何**非空**查询 Bing 都返回 ~96–105 KB、含 10 个 b_algo
# 块——连乱码、`site:` 到不存在的域名也一样；只有空查询回 ~14.7 KB、0 块。
# 所以"取到页面却一个块都解析不出"是**异常**，绝不能当成"没搜到"：
# 那会把"工具坏了"静默地说成"这世上没有"，而使用者无从分辨。
DEGENERATE_PAGE_BYTES = 20000


class SearchError(RuntimeError):
    """搜索链路本身出了问题（页面为空 / 版式变了）——必须显式暴露，不能咽掉。"""


class FetchError(RuntimeError):
    """抓取链路出了问题（URL 非法 / 非文本页 / 网络错误）——显式暴露给模型。"""


def _browser_opener() -> urllib.request.OpenerDirector:
    """带 cookie jar 的浏览器式 opener。

    2026-09-19 实测：无 cookie 的素请求，cn.bing 对同一 query 的 SERP 有
    时段性波动（时而正确人物、时而字典词条）；先访问首页建立会话再搜索，
    请求指纹更接近浏览器，用于压低波动概率。
    """
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    opener.addheaders = list(HEADERS_BROWSER.items())
    return opener


def _search_bing_once(query: str, count: int, *,
                      quoted: bool = False, ensearch: bool = False) -> list[dict[str, str]]:
    core = query.strip().strip('"\'')
    params = {"q": f'"{core}"' if quoted else query, "count": count}
    if ensearch:
        params["ensearch"] = "1"
    opener = _browser_opener()
    try:
        opener.open("https://cn.bing.com/", timeout=TIMEOUT).read(65536)
    except Exception:
        pass  # 首页预热失败不阻断搜索：cookie 只是锦上添花
    url = "https://cn.bing.com/search?" + urllib.parse.urlencode(params)
    with opener.open(url, timeout=TIMEOUT) as r:
        raw = r.read().decode("utf-8", errors="replace")

    out: list[dict[str, str]] = []
    for b in re.findall(r'<li class="b_algo".*?</li>', raw, re.S):
        m = re.search(r'<h2[^>]*>\s*<a[^>]+href="([^"]+)"[^>]*>(.*?)</a>', b, re.S)
        if not m:
            continue
        link = html.unescape(m.group(1))
        title = html.unescape(re.sub(r"<[^>]+>", "", m.group(2))).strip()
        p = re.search(r"<p[^>]*>(.*?)</p>", b, re.S)
        snippet = html.unescape(re.sub(r"<[^>]+>", "", p.group(1))).strip() if p else ""
        if title and link.startswith("http"):
            out.append({"title": title, "url": link, "snippet": snippet})
        if len(out) >= count:
            break

    if not out:
        raise SearchError(
            f"Bing 没有返回可解析的结果（页面 {len(raw)} 字节）："
            + ("页面过小，查询可能为空或被拒。" if len(raw) < DEGENERATE_PAGE_BYTES
               else "页面大小正常却解析不出条目，Bing 版式可能已变，需维护本工具。"))
    return out


def _longest_cjk_run(query: str) -> str:
    """取查询里最长的连续中文串（如「王诗翔」）；无则返回空。"""
    runs = re.findall(r"[一-鿿]{2,}", query)
    return max(runs, key=len) if runs else ""


def _looks_degenerate(query: str, hits: list[dict[str, str]]) -> bool:
    """分词跑偏检测：最长的中文关键词在全部标题+摘要里一次都没出现。

    实测（2026-09-19）：搜「王诗翔」时 cn.bing 常把名字拆散，整页返回
    「王」字字典/王姓/王者荣耀，与查询语义完全脱钩。此为启发式，宁可
    漏判（多发一次变体重试）不可误伤正常结果。
    """
    core = _longest_cjk_run(query)
    if not core or not hits:
        return False
    joined = "".join(h["title"] + h["snippet"] for h in hits)
    return core not in joined


def search(query: str, count: int = DEFAULT_COUNT) -> list[dict[str, str]]:
    """三级重试：原样 → 加引号 → 加引号+国际版。首击退化时服务端自愈。"""
    last_err: Exception | None = None
    hits: list[dict[str, str]] | None = None
    for attempt, flags in enumerate(({}, {"quoted": True}, {"quoted": True, "ensearch": True})):
        try:
            hits = _search_bing_once(query, count, **flags)
        except SearchError as e:
            last_err = e
            continue
        if attempt == 0 or not _looks_degenerate(query, hits):
            return hits
        # 首击分词跑偏：落入下一级变体
    if hits:
        return hits  # 各变体都退化：返回可解析结果，交模型按描述换路
    raise last_err if last_err is not None else SearchError("Bing 搜索失败。")


def _decode_body(body: bytes, content_type: str) -> str:
    """按 content-type 的 charset 解码，缺省 utf-8；坏字节不致命。"""
    m = re.search(r"charset=([\w-]+)", content_type.lower())
    if m:
        try:
            return body.decode(m.group(1))
        except (LookupError, UnicodeDecodeError):
            pass
    return body.decode("utf-8", errors="replace")


# ---------- 学术检索（官方 API，免 key；Semantic Scholar 实测 429 弃用） ----------

# NCBI 与 OpenAlex 的可选身份信息：都从环境读（服务端 0600 .env），不给也能用。
# NCBI 带 api_key 后限速 3→10 req/s；OpenAlex 带 mailto 进官方 polite pool
# （共享 IP 下更稳）。凭据绝不写进仓库或文档。
NCBI_API_KEY = os.environ.get("NCBI_API_KEY", "")
NCBI_EMAIL = os.environ.get("NCBI_EMAIL", "")
NCBI_TOOL = "websearch-mcp"


def _ncbi_params(params: dict) -> dict:
    params = dict(params)
    if NCBI_API_KEY:
        params["api_key"] = NCBI_API_KEY
    if NCBI_EMAIL:
        params["email"] = NCBI_EMAIL
    params.setdefault("tool", NCBI_TOOL)
    return params


def _scholar_get(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=SCHOLAR_TIMEOUT) as r:
        return r.read()


def _scholar_openalex(query: str, count: int) -> list[str]:
    sel = ("display_name,publication_year,doi,cited_by_count,"
           "authorships,primary_location")
    params = {"search": query, "per-page": count, "select": sel}
    if NCBI_EMAIL:  # OpenAlex polite pool：附邮箱获更稳的共享限速
        params["mailto"] = NCBI_EMAIL
    url = "https://api.openalex.org/works?" + urllib.parse.urlencode(params)
    data = json.loads(_scholar_get(url))
    out = []
    for w in data.get("results", []):
        authors = ", ".join(a.get("author", {}).get("display_name", "")
                            for a in w.get("authorships", [])[:3]).strip(", ")
        src = (w.get("primary_location") or {}).get("source") or {}
        out.append(f"{w.get('display_name')} | {authors} | {w.get('publication_year')} "
                   f"| {src.get('display_name')} | 被引 {w.get('cited_by_count')} | {w.get('doi')}")
    return out


def _scholar_pubmed(query: str, count: int) -> list[str]:
    base = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils"
    url = base + "/esearch.fcgi?" + urllib.parse.urlencode(_ncbi_params(
        {"db": "pubmed", "term": query, "retmax": count, "retmode": "json"}))
    ids = json.loads(_scholar_get(url))["esearchresult"].get("idlist", [])
    if not ids:
        return []
    url = base + "/esummary.fcgi?" + urllib.parse.urlencode(_ncbi_params(
        {"db": "pubmed", "id": ",".join(ids), "retmode": "json"}))
    docs = json.loads(_scholar_get(url))["result"]
    out = []
    for pid in docs.get("uids", []):
        d = docs[pid]
        out.append(f"{d.get('title')} | {d.get('lastauthor')} | {d.get('pubdate')} "
                   f"| {d.get('fulljournalname')} | https://pubmed.ncbi.nlm.nih.gov/{pid}/")
    return out


def _scholar_arxiv(query: str, count: int) -> list[str]:
    url = ("http://export.arxiv.org/api/query?"
           + urllib.parse.urlencode({"search_query": f"all:{query}",
                                     "max_results": count,
                                     "sortBy": "relevance"}))
    xml = _scholar_get(url).decode("utf-8", errors="replace")
    out = []
    for entry in re.findall(r"<entry>(.*?)</entry>", xml, re.S):
        title = re.sub(r"\s+", " ", re.search(r"<title>(.*?)</title>", entry, re.S).group(1)).strip()
        authors = ", ".join(re.findall(r"<name>(.*?)</name>", entry)[:3])
        year = re.search(r"<published>(\d{4})", entry)
        aid = re.search(r"<id>(http://arxiv.org/abs/.*?)</id>", entry)
        out.append(f"{title} | {authors} | {year.group(1) if year else ''} | {aid.group(1) if aid else ''}")
    return out


def _scholar_crossref(query: str, count: int) -> list[str]:
    sel = "title,author,container-title,issued,DOI,is-referenced-by-count"
    url = ("https://api.crossref.org/works?"
           + urllib.parse.urlencode({"query": query, "rows": count, "select": sel}))
    items = json.loads(_scholar_get(url))["message"]["items"]
    out = []
    for w in items:
        authors = ", ".join(f"{a.get('family', '')} {a.get('given', '')}".strip()
                            for a in w.get("author", [])[:3]).strip(", ")
        year = (w.get("issued", {}).get("date-parts") or [[None]])[0][0]
        title = (w.get("title") or [""])[0]
        venue = (w.get("container-title") or [""])[0]
        out.append(f"{title} | {authors} | {year} | {venue} "
                   f"| 被引 {w.get('is-referenced-by-count')} | https://doi.org/{w.get('DOI')}")
    return out


SCHOLAR_SOURCES = {
    "openalex": _scholar_openalex,   # 全学科，含引用数（默认）
    "pubmed": _scholar_pubmed,       # 生物医学（本实验室主场景）
    "arxiv": _scholar_arxiv,         # 预印本
    "crossref": _scholar_crossref,   # DOI 元数据
}


def scholar_search(query: str, source: str = "openalex",
                   count: int = DEFAULT_SCHOLAR_COUNT) -> list[str]:
    fn = SCHOLAR_SOURCES.get(source)
    if fn is None:
        raise SearchError(f"未知学术源 {source}，可用：{'/'.join(SCHOLAR_SOURCES)}")
    hits = fn(query, count)
    if not hits:
        raise SearchError(f"{source} 返回 0 条结果：可能确实没有相关文献。")
    return hits


def _is_public_http_target(url: str) -> bool:
    """共享实例的内网防护：目标必须是公网 http(s) 地址。

    解析所有 A/AAAA 记录，任一落在 loopback / 私网 / 链路本地即拒绝——
    防止 fetch_page 被当成探测 labapi、网关、NAS 等内网服务的跳板。
    """
    scheme = urllib.parse.urlsplit(url).scheme.lower()
    if scheme not in ("http", "https"):
        return False
    host = (urllib.parse.urlsplit(url).hostname or "").lower()
    if not host:
        return False
    try:
        infos = socket.getaddrinfo(host, None)
    except socket.gaierror:
        return False  # 解析不了的域名公网也访问不了，一并拒绝
    for info in infos:
        ip = ipaddress.ip_address(info[4][0])
        if (ip.is_private or ip.is_loopback or ip.is_link_local
                or ip.is_reserved or ip.is_multicast):
            return False
    return True


class _PublicOnlyRedirect(urllib.request.HTTPRedirectHandler):
    """重定向逐跳复检：302 到内网地址是 SSRF 防护最容易被绕过的口子。"""

    def __init__(self, public_only: bool):
        self._public_only = public_only

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if self._public_only and not _is_public_http_target(newurl):
            raise FetchError(f"重定向目标未通过内网防护检查，已拒绝：{newurl[:80]}")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def fetch_page(url: str, max_chars: int = FETCH_CHARS, *,
               public_only: bool = False) -> str:
    """抓 URL 并返回正文纯文本。二进制页显式报错，不返回乱码。"""
    if not url.lower().startswith(("http://", "https://")):
        raise FetchError(f"只支持 http(s) URL，收到：{url[:80]}")
    if public_only and not _is_public_http_target(url):
        raise FetchError(
            "共享实例禁止抓取内网/保留地址（含解析到私网 IP 的域名）。")
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    try:
        opener = urllib.request.build_opener(_PublicOnlyRedirect(public_only))
        with opener.open(req, timeout=TIMEOUT) as r:
            ctype = (r.headers.get("content-type") or "").lower()
            if ctype and not any(k in ctype for k in ("text/", "json", "xml")):
                raise FetchError(f"非文本页面（content-type: {ctype}），无法抓正文。")
            chunks: list[bytes] = []
            total = 0
            while total < MAX_DOWNLOAD_BYTES:
                chunk = r.read(65536)
                if not chunk:
                    break
                chunks.append(chunk)
                total += len(chunk)
    except FetchError:
        raise
    except Exception as e:
        raise FetchError(f"{type(e).__name__}: {e}") from e

    raw = _decode_body(b"".join(chunks), ctype)
    raw = re.sub(r"<(script|style|noscript|svg)[^>]*>.*?</\1>", " ", raw, flags=re.S | re.I)
    text = html.unescape(re.sub(r"<[^>]+>", " ", raw))
    text = re.sub(r"\s+", " ", text).strip()
    if not text:
        raise FetchError("页面取到了但没有可提取的文本（可能需 JS 渲染，或被反爬拦截）。")
    if len(text) > max_chars:
        return text[:max_chars] + f" …[正文已截断至 {max_chars} 字符，原文更长]"
    return text


TOOL = {
    "name": "web_search",
    "description": ("搜索互联网并返回标题、链接与摘要。用于获取模型知识截止之后"
                    "的信息、实时新闻、或需要引用的资料。摘要往往不足以回答细节"
                    "（版本号、日期、数据、原文表述）——拿到结果后挑最相关的 "
                    "1–2 个链接用 fetch_page 读正文再作答，回答时给出出处 URL。"
                    "查不到时如实报告，不要编造。"
                    "人物/机构等实体查询注意：中文人名常被搜索引擎分词而搜不到；"
                    "结果与上次相同或全是无关词条时立刻换策略——改英文名+平台词，"
                    "或直接猜规范 URL（如 github.com/<用户名>、<名>.github.io）"
                    "用 fetch_page 验证。回答人物事实时只陈述页面可证实的内容，"
                    "自己记忆里的信息须标注「未经页面证实」。"),
    "inputSchema": {
        "type": "object",
        "properties": {
            "query": {"type": "string", "description": "搜索关键词"},
            "count": {"type": "integer", "description": f"返回条数，默认 {DEFAULT_COUNT}"},
        },
        "required": ["query"],
    },
}

TOOL_FETCH = {
    "name": "fetch_page",
    "description": ("抓取指定 URL 的网页并返回正文纯文本（截断至 "
                    f"{FETCH_CHARS} 字符）。典型用法：web_search 之后，从结果里"
                    "挑最相关的链接用本工具读正文——只看摘要常常答不对细节。"),
    "inputSchema": {
        "type": "object",
        "properties": {
            "url": {"type": "string", "description": "要抓取的网页 URL"},
        },
        "required": ["url"],
    },
}

TOOL_SCHOLAR = {
    "name": "scholar_search",
    "description": ("检索学术文献（官方数据库 API，返回 标题 | 作者 | 年份 | "
                    "期刊/仓库 | 被引/链接）。找论文、查作者代表作、对比研究时"
                    "用本工具而非 web_search。source 选择：openalex（全学科+"
                    "被引数，默认）、pubmed（生物医学，本实验室主场景）、"
                    "arxiv（预印本）、crossref（DOI 元数据）。通用网页检索"
                    "仍用 web_search。"),
    "inputSchema": {
        "type": "object",
        "properties": {
            "query": {"type": "string", "description": "学术查询词（英文效果最好）"},
            "source": {"type": "string", "enum": list(SCHOLAR_SOURCES),
                       "description": "学术数据库，默认 openalex"},
            "count": {"type": "integer", "description": f"返回条数，默认 {DEFAULT_SCHOLAR_COUNT}"},
        },
        "required": ["query"],
    },
}


def _text(mid: object, text: str, *, is_error: bool = False) -> dict:
    result: dict = {"content": [{"type": "text", "text": text}]}
    if is_error:
        result["isError"] = True
    return {"jsonrpc": "2.0", "id": mid, "result": result}


def _as_count(value: object) -> int:
    """模型可能把 count 传成 null / 字符串 / 负数——坏值回退默认，不因此报错。"""
    try:
        n = int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return DEFAULT_COUNT
    return n if n > 0 else DEFAULT_COUNT


def _run_tool(name: object, args: dict, *, public_only: bool = False) -> str:
    if name == "fetch_page":
        url = str(args.get("url") or "").strip()
        if not url:
            raise FetchError("URL 为空。")
        return fetch_page(url, public_only=public_only)
    if name == "scholar_search":
        query = str(args.get("query") or "").strip()
        if not query:
            raise SearchError("查询关键词为空。")
        source = str(args.get("source") or "openalex")
        hits = scholar_search(query, source, _as_count(args.get("count", DEFAULT_SCHOLAR_COUNT)))
        return "\n\n".join(f"{i}. {h}" for i, h in enumerate(hits, 1))
    query = str(args.get("query") or "").strip()
    if not query:
        raise SearchError("查询关键词为空。")
    hits = search(query, _as_count(args.get("count", DEFAULT_COUNT)))
    return "\n\n".join(f"{i}. {h['title']}\n   {h['url']}\n   {h['snippet']}"
                       for i, h in enumerate(hits, 1))


def handle(msg: dict, *, public_only: bool = False) -> dict | None:
    method, mid = msg.get("method"), msg.get("id")

    if method == "initialize":
        return {"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": (msg.get("params") or {}).get("protocolVersion", "2024-11-05"),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "websearch", "version": "1.4.2"}}}
    if method == "ping":                      # MCP 规定的保活方法，回空 result
        return {"jsonrpc": "2.0", "id": mid, "result": {}}
    if method in ("notifications/initialized", "notifications/cancelled"):
        return None
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": mid, "result": {"tools": [TOOL, TOOL_FETCH, TOOL_SCHOLAR]}}
    if method == "tools/call":
        params = msg.get("params") or {}
        args = params.get("arguments") or {}
        try:
            return _text(mid, _run_tool(params.get("name"), args,
                                        public_only=public_only))
        except (SearchError, FetchError) as e:  # 链路问题：消息本身就是给人看的
            return _text(mid, f"失败：{e}", is_error=True)
        except Exception as e:                  # 网络等意外：带上类型名便于排障
            return _text(mid, f"失败：{type(e).__name__}: {e}", is_error=True)
    if mid is not None:
        return {"jsonrpc": "2.0", "id": mid,
                "error": {"code": -32601, "message": f"未知方法 {method}"}}
    return None


def main_stdio() -> None:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        resp = handle(msg)
        if resp is not None:
            sys.stdout.write(json.dumps(resp, ensure_ascii=False) + "\n")
            sys.stdout.flush()


def main_http(listen: str, token: str) -> None:
    host, _, port = listen.rpartition(":")
    expected = f"Bearer {token}"

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        timeout = 60  # 慢连接/半开连接挂死线程的兜底

        def _authed(self) -> bool:
            # 常量时间比较：不给 token 逐字节试探留计时侧信道
            return hmac.compare_digest(self.headers.get("Authorization") or "",
                                       expected)

        def do_POST(self) -> None:
            if self.path.rstrip("/") != "/mcp":
                self.send_error(404)
                return
            if not self._authed():
                self.send_error(401, "missing or wrong bearer token")
                return
            try:
                length = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                self.send_error(400, "bad Content-Length")
                return
            if length < 0:
                self.send_error(400, "bad Content-Length")
                return
            if length > MAX_RPC_BODY_BYTES:
                self.send_error(413, "body too large")
                return
            try:
                msg = json.loads(self.rfile.read(length))
            except ValueError:
                self.send_error(400, "body is not JSON")
                return
            resp = handle(msg, public_only=True)
            if resp is None:                  # 通知类（无 id）：确认收到即可
                self.send_response(202)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            body = json.dumps(resp, ensure_ascii=False).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:
            if self.path.rstrip("/") == "/health":
                body = b'{"ok":true}'
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            # 无服务端主动推送需求：Streamable HTTP 允许对 GET 返回 405
            self.send_error(405, "this server is POST-only (stateless)")

        def log_message(self, fmt: str, *args: object) -> None:
            pass  # 默认每请求一行太吵；查询内容也不该落日志

    server = ThreadingHTTPServer((host or "127.0.0.1", int(port)), Handler)
    print(f"[websearch-mcp] http listen={listen} (token auth on, "
          f"fetch public_only)", flush=True)
    server.serve_forever()


def main() -> None:
    parser = argparse.ArgumentParser(description="websearch MCP (stdio | http)")
    parser.add_argument("--http", metavar="HOST:PORT",
                        help="以 Streamable HTTP 模式监听（缺省为 stdio 模式）")
    parser.add_argument("--token", default="",
                        help="HTTP 模式的 Bearer token（建议必配）")
    args = parser.parse_args()
    if args.http:
        if not args.token:
            raise SystemExit("HTTP 模式必须配 --token（公网裸奔的搜索+抓取服务不可接受）")
        main_http(args.http, args.token)
    else:
        main_stdio()


if __name__ == "__main__":
    main()

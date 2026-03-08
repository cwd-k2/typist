"""Pygments lexer for Perl with Typist type system annotations.

Extends PerlLexer to highlight:
- Declaration keywords (typedef, struct, effect, match, ...)
- Built-in type names (Int, Str, Bool, ...)
- User-defined type names and constructors (uppercase identifiers)
- Type expressions inside :sig() annotations (type vars, arrows, effects)
- Type strings in declarations (struct fields, typedef/newtype targets, etc.)
"""

import re
from pygments.lexers.perl import PerlLexer
from pygments.token import (
    Token, Keyword, Name, Operator, Punctuation, Whitespace,
)


class TypistLexer(PerlLexer):
    """Perl + Typist type system lexer."""

    name = 'Typist'
    url = 'https://github.com/cwd-k2/typist'
    aliases = ['typist']
    filenames = []  # only via explicit ```typist fence

    DECL_KEYWORDS = frozenset({
        'typedef', 'newtype', 'struct', 'datatype', 'enum',
        'effect', 'typeclass', 'instance', 'match', 'handle',
        'protocol', 'optional', 'declare',
    })

    BUILTIN_TYPES = frozenset({
        'Int', 'Str', 'Bool', 'Double', 'Num', 'Any', 'Void',
        'Never', 'Undef', 'ArrayRef', 'HashRef', 'Maybe',
        'Array', 'Hash', 'Ref', 'CodeRef', 'Tuple', 'Row',
    })

    PASSTHROUGH = frozenset({
        'BEGIN', 'END', 'CHECK', 'INIT', 'UNITCHECK',
        'AUTOLOAD', 'DESTROY', 'CORE', 'SUPER',
        'STDIN', 'STDOUT', 'STDERR',
        'EXPORT', 'EXPORT_OK', 'ISA', 'VERSION',
        'Exporter', 'Carp',
    })

    def get_tokens_unprocessed(self, text, stack=('root',)):
        tokens = list(PerlLexer.get_tokens_unprocessed(self, text, stack))

        in_sig = False
        sig_depth = 0
        in_decl = False

        for i, (idx, tok, val) in enumerate(tokens):
            # ── Case 1: PerlLexer merged :sig(...) into one token ──
            if ':sig(' in val:
                yield from self._split_merged_sig(idx, val)
                continue

            # ── Case 2: 'sig' as separate token after ':' ──
            if not in_sig and val == 'sig' and tok in Token.Name:
                prev = _prev_nonws(tokens, i)
                if prev is not None and prev[2] == ':':
                    in_sig = True
                    sig_depth = 0
                    yield idx, Name.Decorator, val
                    continue

            # ── Inside :sig() (multi-token path) ──
            if in_sig:
                sig_depth += val.count('(') - val.count(')')
                if sig_depth <= 0 and ')' in val:
                    in_sig = False
                if tok in Token.Name:
                    yield idx, _classify_type(val, self.BUILTIN_TYPES), val
                elif val in ('!', '->'):
                    yield idx, Operator, val
                else:
                    yield idx, tok, val
                continue

            # ── Track declaration context ──
            if tok in Token.Name and val in self.DECL_KEYWORDS:
                in_decl = True
            if in_decl and val == ';':
                in_decl = False

            # ── Inside declaration: split type strings ──
            if in_decl and tok in Token.Literal.String and len(val) >= 3:
                quote = val[0]
                if quote in ("'", '"') and val[-1] == quote:
                    content = val[1:-1]
                    if _is_type_string(content):
                        yield idx, Punctuation, quote
                        yield from self._tokenize_type_expr(idx + 1, content)
                        yield idx + len(val) - 1, Punctuation, quote
                        continue

            # ── Regular code reclassification ──
            if tok in Token.Name:
                yield idx, self._classify_name(val, tok), val
            else:
                yield idx, tok, val

    # ── Merged-token splitter ────────────────────────────

    def _split_merged_sig(self, base, val):
        """Split a PerlLexer token that contains :sig(...) plus trailing code."""
        sig_pos = val.index(':sig(')

        # Anything before :sig (rare, usually empty)
        if sig_pos > 0:
            yield from _tokenize_code(base, val[:sig_pos])

        # :sig decorator
        yield base + sig_pos, Name.Decorator, ':sig'

        # Opening paren
        p = sig_pos + 4
        yield base + p, Punctuation, '('
        p += 1

        # Find matching close paren
        depth = 1
        scan = p
        while scan < len(val) and depth > 0:
            if val[scan] == '(':
                depth += 1
            elif val[scan] == ')':
                depth -= 1
            scan += 1

        # Type expression content
        yield from self._tokenize_type_expr(base + p, val[p:scan - 1])

        # Closing paren
        yield base + scan - 1, Punctuation, ')'

        # Trailing code (function params + brace)
        if scan < len(val):
            yield from _tokenize_code(base + scan, val[scan:])

    # ── Type expression tokenizer ────────────────────────

    def _tokenize_type_expr(self, base, content):
        """Tokenize a type expression like (Person, Str) -> Int ![Console]."""
        for m in _TYPE_RE.finditer(content):
            idx = base + m.start()
            s = m.group()
            g = m.lastgroup
            if g == 'ws':
                yield idx, Token.Text.Whitespace, s
            elif g == 'arrow':
                yield idx, Operator, s
            elif g == 'bang':
                yield idx, Operator, s
            elif g == 'dots':
                yield idx, Punctuation, s
            elif g == 'punct':
                yield idx, Punctuation, s
            elif g == 'kw':
                yield idx, Keyword, s
            elif g == 'upper':
                yield idx, _classify_type(s, self.BUILTIN_TYPES), s
            elif g == 'lower':
                yield idx, Name.Variable.Global, s
            elif g == 'num':
                yield idx, Token.Literal.Number.Integer, s
            else:
                yield idx, Token.Text, s

    # ── Name classifier (outside :sig) ───────────────────

    def _classify_name(self, val, tok):
        if val in self.DECL_KEYWORDS:
            return Keyword.Declaration
        if val in self.BUILTIN_TYPES:
            return Keyword.Type
        if val[:1].isupper() and val not in self.PASSTHROUGH:
            return Name.Class
        return tok


# ── Helpers (module-level for reuse) ─────────────────────

def _prev_nonws(tokens, i):
    j = i - 1
    while j >= 0:
        if tokens[j][2].strip():
            return tokens[j]
        j -= 1
    return None


def _is_type_string(content):
    """Check if string content looks like a type expression."""
    content = content.strip()
    if not content:
        return False
    return content[0].isupper() or content[0] in ('(', '{')


def _classify_type(val, builtins):
    """Classify a name inside a type expression."""
    if val in builtins:
        return Keyword.Type
    if val == 'forall':
        return Keyword
    if val[:1].isupper():
        return Name.Variable.Global if len(val) == 1 else Name.Class
    return Name.Variable.Global


_TYPE_RE = re.compile(r"""
    (?P<ws>     \s+)                  |
    (?P<arrow>  ->|=>)                 |
    (?P<bang>   !)                    |
    (?P<dots>   \.\.\.)              |
    (?P<punct>  [(),\[\]<>:+&|{}?])  |
    (?P<kw>     forall)              |
    (?P<upper>  [A-Z][A-Za-z0-9_]*)  |
    (?P<lower>  [a-z_][a-z0-9_]*)    |
    (?P<num>    \d+)                  |
    (?P<other>  .)
""", re.VERBOSE)


_CODE_RE = re.compile(r"""
    (?P<ws>     \s+)                  |
    (?P<var>    [\$@%]\w+)            |
    (?P<sigil>  [\$@%])              |
    (?P<num>    \d+)                  |
    (?P<str>    "[^"]*"|'[^']*')     |
    (?P<op>     =>|=)                 |
    (?P<punct>  [(){}\[\],;:])       |
    (?P<word>   \w+)                  |
    (?P<other>  .)
""", re.VERBOSE)


def _tokenize_code(base, val):
    """Best-effort tokenization for Perl code fragments."""
    for m in _CODE_RE.finditer(val):
        idx = base + m.start()
        s = m.group()
        g = m.lastgroup
        if g == 'ws':
            yield idx, Token.Text.Whitespace, s
        elif g in ('var', 'sigil'):
            yield idx, Name.Variable, s
        elif g == 'num':
            yield idx, Token.Literal.Number.Integer, s
        elif g == 'str':
            yield idx, Token.Literal.String, s
        elif g == 'op':
            yield idx, Operator, s
        elif g == 'punct':
            yield idx, Punctuation, s
        elif g == 'word':
            yield idx, Token.Name, s
        else:
            yield idx, Token.Text, s

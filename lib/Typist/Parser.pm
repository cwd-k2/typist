package Typist::Parser;
use v5.40;

our $VERSION = '0.01';

use Typist::Type::Atom;
use Typist::Type::Param;
use Typist::Type::Union;
use Typist::Type::Intersection;
use Typist::Type::Func;
use Typist::Type::Record;
use Typist::Type::Var;
use Typist::Type::Alias;
use Typist::Type::Literal;
use Typist::Type::Quantified;

use Typist::Type::Row;
use Typist::Type::Eff;

my %PRIMITIVES = map { $_ => 1 } qw(Any Void Never Undef Bool Int Double Num Str);

# DSL constructor names that use (...) syntax
my %DSL_CONSTRUCTORS = (
    Record  => \&_parse_dsl_record,
    Func    => \&_parse_dsl_func,
    Alias   => \&_parse_dsl_alias,
    # Parametric: ArrayRef(...), HashRef(...), Maybe(...), Tuple(...), Ref(...), CodeRef(...)
    # Array/Hash are aliases for ArrayRef/HashRef
    (map { $_ => \&_parse_dsl_param } qw(ArrayRef HashRef Array Hash Maybe Tuple Ref CodeRef)),
);

# ── Parse Cache (LRU) ────────────────────────────
#
# Each cache stores [result, epoch] pairs. On overflow, the oldest 25%
# of entries (by access epoch) are evicted, preserving hot entries.

my %_PARSE_CACHE;         # expr => [result, epoch]
my %_ANNOTATION_CACHE;    # input => [result, epoch]
my $_CACHE_LIMIT = 1000;
my $_CACHE_EPOCH = 0;

sub _cache_evict ($cache) {
    my $keep = int($_CACHE_LIMIT * 3 / 4);
    my @sorted = sort { $cache->{$a}[1] <=> $cache->{$b}[1] } keys %$cache;
    delete $cache->{$sorted[$_]} for 0 .. @sorted - $keep - 1;
}

# ── Public API ────────────────────────────────────

sub parse ($class, $expr) {
    if (my $entry = $_PARSE_CACHE{$expr}) {
        $entry->[1] = ++$_CACHE_EPOCH;
        return $entry->[0];
    }

    my @tokens = _tokenize($expr);
    my $pos    = 0;
    my $result = _parse_union(\@tokens, \$pos);
    die "Typist::Parser: unexpected token '$tokens[$pos]' at position $pos in '$expr'"
        if $pos < @tokens;

    _cache_evict(\%_PARSE_CACHE) if keys %_PARSE_CACHE >= $_CACHE_LIMIT;
    $_PARSE_CACHE{$expr} = [$result, ++$_CACHE_EPOCH];
    $result;
}

# ── Lexer ─────────────────────────────────────────

sub _tokenize ($input) {
    my @tokens;
    pos($input) = 0;

    while (pos($input) < length($input)) {
        next if $input =~ /\G\s+/gc;

        if    ($input =~ /\G(\.\.\.)/gc)            { push @tokens, $1 }
        elsif ($input =~ /\G(->)/gc)              { push @tokens, $1 }
        elsif ($input =~ /\G(=>)/gc)              { push @tokens, $1 }
        elsif ($input =~ /\G("(?:[^"\\]|\\.)*")/gc) { push @tokens, $1 }
        elsif ($input =~ /\G('(?:[^'\\]|\\.)*')/gc) { push @tokens, $1 }
        elsif ($input =~ /\G(-?\d+(?:\.\d+)?)/gc)   { push @tokens, $1 }
        elsif ($input =~ /\G([A-Za-z_]\w*)/gc)    { push @tokens, $1 }
        elsif ($input =~ /\G([\[\]{}(),.|&?!:<>+])/gc)  { push @tokens, $1 }
        else {
            my $ch = substr($input, pos($input), 1);
            die "Typist::Parser: unexpected character '$ch' in '$input'";
        }
    }

    @tokens;
}

# ── Recursive Descent ─────────────────────────────

# union_type ::= inter_type ('|' inter_type)*
sub _parse_union ($tokens, $pos) {
    my @members = (_parse_intersection($tokens, $pos));

    while ($$pos < @$tokens && $tokens->[$$pos] eq '|') {
        $$pos++;
        push @members, _parse_intersection($tokens, $pos);
    }

    @members == 1 ? $members[0] : Typist::Type::Union->new(@members);
}

# inter_type ::= primary (('&' | '+') primary)*
sub _parse_intersection ($tokens, $pos) {
    my @members = (_parse_primary($tokens, $pos));

    while ($$pos < @$tokens && ($tokens->[$$pos] eq '&' || $tokens->[$$pos] eq '+')) {
        $$pos++;
        push @members, _parse_primary($tokens, $pos);
    }

    @members == 1 ? $members[0] : Typist::Type::Intersection->new(@members);
}

# primary ::= named | struct | '(' type_expr ')'
sub _parse_primary ($tokens, $pos) {
    die "Typist::Parser: unexpected end of input" if $$pos >= @$tokens;

    my $tok = $tokens->[$$pos];

    return _parse_record($tokens, $pos)     if $tok eq '{';
    return _parse_grouped($tokens, $pos)    if $tok eq '(';
    return _parse_literal($tokens, $pos)    if $tok =~ /\A["'\d]/ || $tok =~ /\A-\d/;
    return _parse_quantified($tokens, $pos) if $tok eq 'forall';
    return _parse_named($tokens, $pos);
}

# named ::= IDENT ('[' param_list ']')? | DSL_NAME '(' ... ')'
# param_list ::= type_expr (',' type_expr)* ('->' type_expr)?
sub _parse_named ($tokens, $pos) {
    my $name = $tokens->[$$pos++];

    # DSL constructor dispatch: Name(...)
    if ($$pos < @$tokens && $tokens->[$$pos] eq '(' && $DSL_CONSTRUCTORS{$name}) {
        return $DSL_CONSTRUCTORS{$name}->($name, $tokens, $pos);
    }

    # Without parameters — resolve as Atom, Var, or Alias
    unless ($$pos < @$tokens && $tokens->[$$pos] eq '[') {
        return _resolve_name($name);
    }

    # Consume '['
    $$pos++;
    my ($params, $return_type, $effect_row) = _parse_param_list($tokens, $pos, ']');
    die "Typist::Parser: expected ']' after parameter list"
        unless $$pos < @$tokens && $tokens->[$$pos] eq ']';
    $$pos++;

    # Known constructors (ArrayRef, Maybe, etc.) and primitives: special handling
    if ($DSL_CONSTRUCTORS{$name} || $PRIMITIVES{$name}) {
        return _resolve_param_constructor($name, $params, $return_type, $effect_row);
    }

    # Everything else: resolve base via _resolve_name.
    # Single-char uppercase → Var('F'), multi-char → Alias('Functor').
    # Both produce Param with a Type object base for HKT support.
    Typist::Type::Param->new(_resolve_name($name), @$params);
}

# struct ::= '{' struct_fields '}'
sub _parse_record ($tokens, $pos) {
    $$pos++; # consume '{'
    my %fields = _parse_record_fields($tokens, $pos, '}');
    die "Typist::Parser: expected '}'"
        unless $$pos < @$tokens && $tokens->[$$pos] eq '}';
    $$pos++;
    Typist::Type::Record->new(%fields);
}

# Common struct field parser: IDENT '?'? '=>' type_expr (',' ...)*
sub _parse_record_fields ($tokens, $pos, $close) {
    my %fields;
    return %fields if $$pos < @$tokens && $tokens->[$$pos] eq $close;

    my $key = _unquote_struct_key($tokens->[$$pos++]);
    if ($$pos < @$tokens && $tokens->[$$pos] eq '?') {
        $key .= '?';
        $$pos++;
    }
    die "Typist::Parser: expected '=>' after struct key"
        unless $$pos < @$tokens && $tokens->[$$pos] eq '=>';
    $$pos++;
    $fields{$key} = _parse_union($tokens, $pos);

    while ($$pos < @$tokens && $tokens->[$$pos] eq ',') {
        $$pos++;
        last if $$pos < @$tokens && $tokens->[$$pos] eq $close;
        $key = _unquote_struct_key($tokens->[$$pos++]);
        if ($$pos < @$tokens && $tokens->[$$pos] eq '?') {
            $key .= '?';
            $$pos++;
        }
        die "Typist::Parser: expected '=>' after struct key"
            unless $$pos < @$tokens && $tokens->[$$pos] eq '=>';
        $$pos++;
        $fields{$key} = _parse_union($tokens, $pos);
    }

    %fields;
}

# Strip surrounding quotes from a struct key token: 'description?' → description?
sub _unquote_struct_key ($tok) {
    $tok =~ s/\A(['"])(.+)\1\z/$2/;
    $tok;
}

# grouped ::= '(' type_expr ')' | func_type
# func_type ::= '(' param_list? ')' '->' return_type ('!' effect_row)?
sub _parse_grouped ($tokens, $pos) {
    # Look ahead: if matching ')' is followed by '->', it's a function type
    my $depth = 0;
    my $close_pos;
    for my $i ($$pos .. $#$tokens) {
        $depth++ if $tokens->[$i] eq '(';
        if ($tokens->[$i] eq ')') {
            $depth--;
            if ($depth == 0) { $close_pos = $i; last; }
        }
    }

    if (defined $close_pos && $close_pos + 1 < @$tokens && $tokens->[$close_pos + 1] eq '->') {
        return _parse_func_type($tokens, $pos);
    }

    $$pos++; # consume '('
    my $inner = _parse_union($tokens, $pos);

    die "Typist::Parser: expected ')'"
        unless $$pos < @$tokens && $tokens->[$$pos] eq ')';
    $$pos++;

    $inner;
}

# func_type ::= '(' param_list? ')' '->' return_type ('!' effect_row)?
# Variadic: '...' before the last param type: (Int, ...Str) -> Void
sub _parse_func_type ($tokens, $pos) {
    $$pos++; # consume '('

    my @params;
    my $variadic = 0;
    unless ($$pos < @$tokens && $tokens->[$$pos] eq ')') {
        if ($$pos < @$tokens && $tokens->[$$pos] eq '...') {
            $$pos++;
            $variadic = 1;
        }
        push @params, _parse_func_param($tokens, $pos);
        while ($$pos < @$tokens && $tokens->[$$pos] eq ',') {
            $$pos++;
            if ($$pos < @$tokens && $tokens->[$$pos] eq '...') {
                $$pos++;
                $variadic = 1;
            }
            push @params, _parse_func_param($tokens, $pos);
        }
    }

    die "Typist::Parser: expected ')' in function type"
        unless $$pos < @$tokens && $tokens->[$$pos] eq ')';
    $$pos++;

    die "Typist::Parser: expected '->' in function type"
        unless $$pos < @$tokens && $tokens->[$$pos] eq '->';
    $$pos++;

    my $return_type = _parse_union($tokens, $pos);

    my $effects;
    if ($$pos < @$tokens && $tokens->[$$pos] eq '!') {
        $$pos++;
        $effects = _parse_effect_row($tokens, $pos);
    }

    Typist::Type::Func->new(\@params, $return_type, $effects, variadic => $variadic);
}

# Parse a function parameter that may contain a bare arrow function type.
# Inside a param list, A -> B is itself a function type (right-associative).
sub _parse_func_param ($tokens, $pos) {
    my $type = _parse_union($tokens, $pos);

    if ($$pos < @$tokens && $tokens->[$$pos] eq '->') {
        $$pos++;
        my $ret = _parse_func_param($tokens, $pos);
        my $effects;
        if ($$pos < @$tokens && $tokens->[$$pos] eq '!') {
            $$pos++;
            $effects = _parse_effect_row($tokens, $pos);
        }
        $type = Typist::Type::Func->new([$type], $ret, $effects);
    }

    $type;
}

# ── DSL Constructors ─────────────────────────────

# Record(k => V, ...) → Type::Record
sub _parse_dsl_record ($name, $tokens, $pos) {
    $$pos++; # consume '('
    my %fields = _parse_record_fields($tokens, $pos, ')');
    die "Typist::Parser: expected ')' after Record(...)"
        unless $$pos < @$tokens && $tokens->[$$pos] eq ')';
    $$pos++;
    Typist::Type::Record->new(%fields);
}

# Func(A, B, returns => R) or Func(Int, ...Str, returns => R) → Type::Func
sub _parse_dsl_func ($name, $tokens, $pos) {
    $$pos++; # consume '('

    my @params;
    my $return_type;
    my $variadic = 0;

    unless ($$pos < @$tokens && $tokens->[$$pos] eq ')') {
        # Parse args; stop at 'returns' keyword or ')'
        while (1) {
            # Check for 'returns => R' keyword pair
            if ($tokens->[$$pos] eq 'returns'
                && $$pos + 1 < @$tokens && $tokens->[$$pos + 1] eq '=>') {
                $$pos += 2; # consume 'returns' and '=>'
                $return_type = _parse_union($tokens, $pos);
                last;
            }

            if ($$pos < @$tokens && $tokens->[$$pos] eq '...') {
                $$pos++;
                $variadic = 1;
            }

            push @params, _parse_union($tokens, $pos);

            if ($$pos < @$tokens && $tokens->[$$pos] eq ',') {
                $$pos++;
                next;
            }
            last;
        }
    }

    # Parse optional effect row: ![Label, Label, var]
    my $effect_row;
    if ($$pos < @$tokens && $tokens->[$$pos] eq '!') {
        $$pos++;
        $effect_row = _parse_effect_row($tokens, $pos, ')');
    }

    die "Typist::Parser: expected ')' after Func(...)"
        unless $$pos < @$tokens && $tokens->[$$pos] eq ')';
    $$pos++;

    die "Typist::Parser: Func() requires 'returns => Type'"
        unless $return_type;

    Typist::Type::Func->new(\@params, $return_type, $effect_row, variadic => $variadic);
}

# Alias('Name') → resolve as _resolve_name
sub _parse_dsl_alias ($name, $tokens, $pos) {
    $$pos++; # consume '('

    die "Typist::Parser: expected name inside Alias()"
        unless $$pos < @$tokens;

    my $tok = $tokens->[$$pos++];
    my $inner;
    if ($tok =~ /\A['"](.+)['"]\z/) {
        $inner = $1;
    } else {
        $inner = $tok;
    }

    die "Typist::Parser: expected ')' after Alias(...)"
        unless $$pos < @$tokens && $tokens->[$$pos] eq ')';
    $$pos++;

    _resolve_name($inner);
}

# ArrayRef(T), HashRef(K,V), Maybe(T), etc. → same as bracket form
sub _parse_dsl_param ($name, $tokens, $pos) {
    $$pos++; # consume '('
    my ($params, $return_type, $effect_row) = _parse_param_list($tokens, $pos, ')');
    die "Typist::Parser: expected ')' after $name(...)"
        unless $$pos < @$tokens && $tokens->[$$pos] eq ')';
    $$pos++;
    _resolve_param_constructor($name, $params, $return_type, $effect_row);
}

# ── Common Param List / Constructor ──────────────

# Parse a parametric argument list: type_expr (',' type_expr)* ('->' return)? ('!' effects)?
# Returns ($params_aref, $return_type_or_undef, $effect_row_or_undef).
sub _parse_param_list ($tokens, $pos, $close) {
    my @params;
    my $return_type;

    unless ($$pos < @$tokens && $tokens->[$$pos] eq $close) {
        push @params, _parse_union($tokens, $pos);
        while ($$pos < @$tokens && $tokens->[$$pos] eq ',') {
            $$pos++;
            push @params, _parse_union($tokens, $pos);
        }
        if ($$pos < @$tokens && $tokens->[$$pos] eq '->') {
            $$pos++;
            $return_type = _parse_union($tokens, $pos);
        }
    }

    my $effect_row;
    if ($$pos < @$tokens && $tokens->[$$pos] eq '!') {
        $$pos++;
        $effect_row = _parse_effect_row($tokens, $pos, $close);
    }

    (\@params, $return_type, $effect_row);
}

# Resolve a parametric constructor with Maybe/CodeRef desugaring.
sub _resolve_param_constructor ($name, $params, $return_type, $effect_row) {
    # Array and Hash are list types (distinct from ArrayRef/HashRef)

    # Maybe[T] / Maybe(T) → T | Undef
    if ($name eq 'Maybe' && @$params == 1 && !$return_type) {
        return Typist::Type::Union->new(
            $params->[0],
            Typist::Type::Atom->new('Undef'),
        );
    }

    # CodeRef[A -> B ! E] / CodeRef(A -> B ! E) → Func
    if ($name eq 'CodeRef' && $return_type) {
        return Typist::Type::Func->new($params, $return_type, $effect_row);
    }

    Typist::Type::Param->new($name, @$params);
}

# ── Quantified Types (forall) ────────────────────

# forall A B. body | forall A: Num. body
sub _parse_quantified ($tokens, $pos) {
    $$pos++;  # consume 'forall'

    my @vars;
    while ($$pos < @$tokens && $tokens->[$$pos] ne '.') {
        my $var_name = $tokens->[$$pos++];
        my $bound;
        # Optional bound: A: Num or A: Printable + Ord
        if ($$pos < @$tokens && $tokens->[$$pos] eq ':') {
            $$pos++;  # consume ':'
            die "Typist::Parser: expected bound type after ':' in forall"
                unless $$pos < @$tokens;
            my @bounds = (_resolve_name($tokens->[$$pos++]));
            while ($$pos < @$tokens && $tokens->[$$pos] eq '+') {
                $$pos++;  # consume '+'
                die "Typist::Parser: expected bound type after '+' in forall"
                    unless $$pos < @$tokens;
                push @bounds, _resolve_name($tokens->[$$pos++]);
            }
            $bound = @bounds == 1 ? $bounds[0] : Typist::Type::Intersection->new(@bounds);
        }
        push @vars, $bound ? +{ name => $var_name, bound => $bound } : +{ name => $var_name };
    }

    die "Typist::Parser: expected '.' after forall variable list"
        unless $$pos < @$tokens && $tokens->[$$pos] eq '.';
    $$pos++;  # consume '.'

    die "Typist::Parser: forall requires at least one type variable"
        unless @vars;

    # Body may be a bare function type: forall A. A -> A
    # Parse first type, then check for '->' to build Func.
    my $body = _parse_union($tokens, $pos);

    if ($$pos < @$tokens && $tokens->[$$pos] eq '->') {
        $$pos++;  # consume '->'
        my $ret = _parse_union($tokens, $pos);
        my $effects;
        if ($$pos < @$tokens && $tokens->[$$pos] eq '!') {
            $$pos++;
            $effects = _parse_effect_row($tokens, $pos);
        }
        # Wrap the body as params: if body is already a Func (from grouped parse),
        # extract its params; otherwise treat body as a single param.
        my @params = $body->is_func ? ($body) : ($body);
        $body = Typist::Type::Func->new(\@params, $ret, $effects);
    }

    Typist::Type::Quantified->new(vars => \@vars, body => $body);
}

# ── Literal Types ────────────────────────────────

sub _parse_literal ($tokens, $pos) {
    my $tok = $tokens->[$$pos++];

    if ($tok =~ /\A"(.*)"\z/s) {
        return Typist::Type::Literal->new($1, 'Str');
    }
    if ($tok =~ /\A'(.*)'\z/s) {
        return Typist::Type::Literal->new($1, 'Str');
    }
    # Numeric literal
    my $base = $tok =~ /\./ ? 'Double' : 'Int';
    return Typist::Type::Literal->new($tok + 0, $base);
}

# ── Name Resolution ───────────────────────────────

sub _resolve_name ($name) {
    return Typist::Type::Atom->new($name) if $PRIMITIVES{$name};
    return Typist::Type::Var->new($name)  if $name =~ /\A[A-Z]\z/;
    Typist::Type::Alias->new($name);
}

# ── Effect Row (inline) ─────────────────────────

# Parse an effect row within a function type: [Label, Label, var]
# Requires the [...] wrapper after '!'.
sub _parse_effect_row ($tokens, $pos, $close = undef) {
    die "Typist::Parser: expected '[' after '!'"
        unless $$pos < @$tokens
            && $tokens->[$$pos] eq '[';
    $$pos++;  # consume '['

    my @labels;
    my $row_var;
    my %label_states;

    while ($$pos < @$tokens && $tokens->[$$pos] ne ']') {
        my $tok = $tokens->[$$pos++];
        if ($tok =~ /\A[a-z]/) {
            $row_var = $tok;
        } else {
            push @labels, $tok;
            # Optional protocol state: Label<From -> To> or Label<State>
            if ($$pos < @$tokens && $tokens->[$$pos] eq '<') {
                $$pos++;  # consume '<'
                die "Typist::Parser: expected state name after '<' in effect label"
                    unless $$pos < @$tokens;
                my $from = $tokens->[$$pos++];
                my $to;
                if ($$pos < @$tokens && $tokens->[$$pos] eq '->') {
                    $$pos++;  # consume '->'
                    die "Typist::Parser: expected target state after '->' in effect label"
                        unless $$pos < @$tokens;
                    $to = $tokens->[$$pos++];
                } else {
                    $to = $from;
                }
                die "Typist::Parser: expected '>' after state in effect label"
                    unless $$pos < @$tokens && $tokens->[$$pos] eq '>';
                $$pos++;  # consume '>'
                $label_states{$tok} = +{ from => $from, to => $to };
            }
        }
        last unless $$pos < @$tokens && $tokens->[$$pos] eq ',';
        $$pos++;  # consume ','
    }

    die "Typist::Parser: expected ']' after ![...]"
        unless $$pos < @$tokens && $tokens->[$$pos] eq ']';
    $$pos++;  # consume ']'

    Typist::Type::Row->new(
        labels       => \@labels,
        row_var      => $row_var,
        label_states => (%label_states ? \%label_states : +{}),
    );
}

# ── Row Parsing ──────────────────────────────────

# Parse a row expression: "Console, State, r"
# Labels are uppercase-initial identifiers; a trailing lowercase identifier is a row variable.
sub parse_row ($class, $expr) {
    my @tokens = __PACKAGE__->split_type_list($expr);
    my (@labels, $row_var, %label_states);

    for my $i (0 .. $#tokens) {
        my $tok = $tokens[$i];
        $tok =~ s/\A\s+//;
        $tok =~ s/\s+\z//;

        if ($tok =~ /\A[a-z]/) {
            die "Typist::Parser: row variable '$tok' must be the last element in '$expr'"
                unless $i == $#tokens;
            $row_var = $tok;
        } elsif ($tok =~ /\A(\w+)<(.+)>\z/) {
            my ($label, $state_str) = ($1, $2);
            push @labels, $label;
            if ($state_str =~ /\A(\w+)\s*->\s*(\w+)\z/) {
                $label_states{$label} = +{ from => $1, to => $2 };
            } else {
                $label_states{$label} = +{ from => $state_str, to => $state_str };
            }
        } else {
            push @labels, $tok;
        }
    }

    Typist::Type::Row->new(
        labels       => \@labels,
        row_var      => $row_var,
        label_states => (%label_states ? \%label_states : +{}),
    );
}

# ── Unified Annotation Parsing ──────────────────

# Parse a :sig(...) annotation string.
# Supports: simple types, function types, and generic declarations.
#   "Int"                              → { generics_raw => [], type => Atom(Int) }
#   "(Int, Str) -> Bool"               → { generics_raw => [], type => Func }
#   "<T: Num>(T, T) -> T"              → { generics_raw => ["T: Num"], type => Func }
#   "<T, r: Row>(T) -> Str ![Console, r]"
sub parse_annotation ($class, $input) {
    if (my $entry = $_ANNOTATION_CACHE{$input}) {
        $entry->[1] = ++$_CACHE_EPOCH;
        return $entry->[0];
    }

    my @generics_raw;
    my $trimmed = $input;
    $trimmed =~ s/\A\s+//;
    $trimmed =~ s/\s+\z//;

    # Leading <...> → extract generics at string level
    # Carefully skip '>' that appears as part of '->' (arrow in kind annotations).
    if ($trimmed =~ /\A</) {
        my $depth = 0;
        my $end;
        my $len = length($trimmed);
        for my $i (0 .. $len - 1) {
            my $ch = substr($trimmed, $i, 1);
            $depth++ if $ch eq '<';
            if ($ch eq '>') {
                # Check if this '>' is preceded by '-' (part of '->' arrow).
                if ($i > 0 && substr($trimmed, $i - 1, 1) eq '-') {
                    next;  # Skip: this is '->', not a closing bracket.
                }
                $depth--;
                if ($depth == 0) { $end = $i; last; }
            }
        }
        die "Typist::Parser: unbalanced '<' in annotation '$input'" unless defined $end;
        my $gen_str = substr($trimmed, 1, $end - 1);
        @generics_raw = __PACKAGE__->split_type_list($gen_str);
        $trimmed = substr($trimmed, $end + 1);
        $trimmed =~ s/\A\s+//;
    }

    # Tokenize and parse — function type detection handled by _parse_grouped
    my @tokens = _tokenize($trimmed);
    my $pos = 0;
    my $type = _parse_union(\@tokens, \$pos);

    die "Typist::Parser: unexpected token '$tokens[$pos]' in annotation '$input'"
        if $pos < @tokens;

    my $result = +{ generics_raw => \@generics_raw, generics => \@generics_raw, type => $type };
    _cache_evict(\%_ANNOTATION_CACHE) if keys %_ANNOTATION_CACHE >= $_CACHE_LIMIT;
    $_ANNOTATION_CACHE{$input} = [$result, ++$_CACHE_EPOCH];
    $result;
}

# Split a type list on commas, respecting <>, (), and [] nesting.
# Skips '>' that appears as part of '->' (arrow in kind annotations).
sub split_type_list ($class, $str) {
    my @result;
    my $current = '';
    my $depth = 0;
    my @chars = split //, $str;

    for my $i (0 .. $#chars) {
        my $ch = $chars[$i];
        if ($ch eq '<' || $ch eq '(' || $ch eq '[') { $depth++ }
        elsif ($ch eq '>' || $ch eq ')' || $ch eq ']') {
            # Skip '>' that is part of '->'
            unless ($ch eq '>' && $i > 0 && $chars[$i - 1] eq '-') {
                $depth--;
            }
        }

        if ($ch eq ',' && $depth == 0) {
            $current =~ s/\A\s+//;
            $current =~ s/\s+\z//;
            push @result, $current if length $current;
            $current = '';
        } else {
            $current .= $ch;
        }
    }

    $current =~ s/\A\s+//;
    $current =~ s/\s+\z//;
    push @result, $current if length $current;
    @result;
}

# Parse type parameter declarations into structured hashrefs.
# Pure syntax: no Registry lookup, no typeclass/bound classification.
#   'T: Num, U: Show + Ord, r: Row, F: * -> *'
#   => ({ name => 'T', constraint_expr => 'Num' },
#       { name => 'U', constraint_expr => 'Show + Ord' },
#       { name => 'r', is_row_var => 1, var_kind => Kind->Row },
#       { name => 'F', var_kind => Kind->parse('* -> *') })
sub parse_param_decls ($class, $spec) {
    require Typist::Kind;
    my @result;
    for my $decl ($class->split_type_list($spec)) {
        if ($decl =~ /\A(\w+)\s*:\s*(.+)\z/) {
            my ($name, $constraint) = ($1, $2);
            if ($constraint eq 'Row') {
                push @result, +{
                    name       => $name,
                    is_row_var => 1,
                    var_kind   => Typist::Kind->Row,
                };
            } elsif ($constraint =~ /\A[\s\*\-\>]+\z/) {
                push @result, +{
                    name     => $name,
                    var_kind => Typist::Kind->parse($constraint),
                };
            } else {
                push @result, +{ name => $name, constraint_expr => $constraint };
            }
        } else {
            push @result, +{ name => $decl };
        }
    }
    @result;
}

# Decompose a parameterized name: 'Pair[T: Num, U]' → ('Pair', 'T: Num', 'U')
# Returns (name) for plain names, (name, @params) for parameterized.
sub parse_parameterized_name ($class, $spec) {
    if ($spec =~ /\A(\w+)\[(.+)\]\z/) {
        my ($name, $inner) = ($1, $2);
        return ($name, $class->split_type_list($inner));
    }
    return ($spec);
}

1;

__END__

=head1 NAME

Typist::Parser - Recursive-descent parser for type expressions

=head1 SYNOPSIS

    use Typist::Parser;

    # Parse a type expression
    my $type = Typist::Parser->parse('Int');
    my $func = Typist::Parser->parse('(Int, Str) -> Bool');
    my $param = Typist::Parser->parse('ArrayRef[Int]');
    my $union = Typist::Parser->parse('Str | Undef');
    my $struct = Typist::Parser->parse('{ name => Str, age? => Int }');
    my $forall = Typist::Parser->parse('forall A. A -> A');

    # Parse a :sig() annotation string
    my $ann = Typist::Parser->parse_annotation('<T: Num>(T, T) -> T ![Console]');
    # Returns: { generics_raw => ["T: Num"], type => Func(...) }

    # Parse an effect row expression
    my $row = Typist::Parser->parse_row('Console, State, r');

=head1 DESCRIPTION

Typist::Parser implements a recursive-descent parser for the Typist type
expression language. It tokenizes input strings and produces immutable type
objects from the C<Typist::Type::*> hierarchy.

=head1 CLASS METHODS

=head2 parse

    my $type = Typist::Parser->parse($expr);

Parse a type expression string into a type object. Supported syntax:

=over 4

=item Primitives: C<Int>, C<Double>, C<Str>, C<Num>, C<Bool>, C<Any>, C<Void>, C<Never>, C<Undef>

=item Type variables: single uppercase letters (C<T>, C<U>, C<V>, ...)

=item Parameterized types: C<ArrayRef[Int]>, C<HashRef[Str, Int]>, C<Maybe[Str]>

=item Union types: C<Int | Str>

=item Intersection types: C<Readable & Writable>

=item Function types: C<(Int, Str) -E<gt> Bool>

=item Function types with effects: C<(Str) -E<gt> Void ![Console]>

=item Variadic functions: C<(Int, ...Str) -E<gt> Void>

=item Struct types: C<{ name =E<gt> Str, age? =E<gt> Int }>

=item Literal types: C<42>, C<"hello">, C<3.14>

=item Quantified types: C<forall A. A -E<gt> A>, C<forall A: Num. A -E<gt> A>

=item DSL constructors: C<Record(...)>, C<Func(... returns =E<gt> R)>

=back

Dies on malformed input with a diagnostic message.

=head2 parse_annotation

    my $ann = Typist::Parser->parse_annotation($input);

Parse a C<:sig(...)> annotation string. Handles optional leading generic
declarations in angle brackets.

Returns a hashref:

    {
        generics_raw => \@generics,   # e.g. ["T: Num", "r: Row"]
        type         => $type_object, # parsed Type
    }

Examples:

    "Int"                          # simple type
    "(Int, Str) -> Bool"           # function type
    "<T: Num>(T, T) -> T"         # generics + function
    "<T, r: Row>(T) -> Str ![Console, r]"

=head2 split_type_list

    my @parts = Typist::Parser->split_type_list($str);

Split a comma-separated type list, respecting C<< <> >>, C<()>, and C<[]>
nesting. Strips whitespace from each element.

=head2 parse_param_decls

    my @decls = Typist::Parser->parse_param_decls($spec);

Parse type parameter declarations into structured hashrefs. Pure syntax
layer: no Registry lookup or typeclass classification. Each element has
C<name>, and optionally C<constraint_expr>, C<is_row_var>, C<var_kind>.

=head2 parse_parameterized_name

    my ($name, @params) = Typist::Parser->parse_parameterized_name($spec);

Decompose a parameterized name such as C<'Pair[T: Num, U]'> into its base
name and type parameter strings. Returns C<($name)> for plain names.

=head2 parse_row

    my $row = Typist::Parser->parse_row($expr);

Parse an effect row expression of the form C<"Console, State, r">.
Labels are uppercase-initial identifiers; a trailing lowercase identifier
is a row variable. Returns a L<Typist::Type::Row> object.

=head1 TYPE EXPRESSION GRAMMAR

    union      ::= inter ('|' inter)*
    inter      ::= primary ('&' primary)*
    primary    ::= named | struct | literal | quantified | '(' grouped ')'
    named      ::= IDENT ('[' param_list ']')? | DSL_NAME '(' ... ')'
    struct     ::= '{' (key '=>' type (',' key '=>' type)*)? '}'
    func       ::= '(' param_list? ')' '->' return ('!' effect_row)?
    quantified ::= 'forall' var+ '.' body
    literal    ::= NUMBER | STRING
    effect_row ::= '[' (LABEL (',' LABEL)* (',' var)?)? ']'

=head1 SEE ALSO

L<Typist>, L<Typist::Type>, L<Typist::DSL>

=cut

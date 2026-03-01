package Typist::Parser;
use v5.40;

our $VERSION = '0.01';

use Typist::Type::Atom;
use Typist::Type::Param;
use Typist::Type::Union;
use Typist::Type::Intersection;
use Typist::Type::Func;
use Typist::Type::Struct;
use Typist::Type::Var;
use Typist::Type::Alias;
use Typist::Type::Literal;
use Typist::Type::Quantified;

use Typist::Type::Row;
use Typist::Type::Eff;

my %PRIMITIVES = map { $_ => 1 } qw(Any Void Never Undef Bool Int Num Str);

# DSL constructor names that use (...) syntax
my %DSL_CONSTRUCTORS = (
    Struct  => \&_parse_dsl_struct,
    Func    => \&_parse_dsl_func,
    Alias   => \&_parse_dsl_alias,
    # Parametric: ArrayRef(...), HashRef(...), Maybe(...), Tuple(...), Ref(...), CodeRef(...)
    (map { $_ => \&_parse_dsl_param } qw(ArrayRef HashRef Maybe Tuple Ref CodeRef)),
);

# ── Public API ────────────────────────────────────

sub parse ($class, $expr) {
    my @tokens = _tokenize($expr);
    my $pos    = 0;
    my $result = _parse_union(\@tokens, \$pos);
    die "Typist::Parser: unexpected token '$tokens[$pos]' at position $pos in '$expr'"
        if $pos < @tokens;
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
        elsif ($input =~ /\G([\[\]{}(),.|&?!:])/gc)  { push @tokens, $1 }
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

# inter_type ::= primary ('&' primary)*
sub _parse_intersection ($tokens, $pos) {
    my @members = (_parse_primary($tokens, $pos));

    while ($$pos < @$tokens && $tokens->[$$pos] eq '&') {
        $$pos++;
        push @members, _parse_primary($tokens, $pos);
    }

    @members == 1 ? $members[0] : Typist::Type::Intersection->new(@members);
}

# primary ::= named | struct | '(' type_expr ')'
sub _parse_primary ($tokens, $pos) {
    die "Typist::Parser: unexpected end of input" if $$pos >= @$tokens;

    my $tok = $tokens->[$$pos];

    return _parse_struct($tokens, $pos)     if $tok eq '{';
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

    # Type variable application: F[T] → Param(Var('F'), [Var('T')])
    # Single uppercase letter bases are type variables, not constructors.
    if ($name =~ /\A[A-Z]\z/) {
        return Typist::Type::Param->new(
            Typist::Type::Var->new($name), @$params,
        );
    }

    _resolve_param_constructor($name, $params, $return_type, $effect_row);
}

# struct ::= '{' struct_fields '}'
sub _parse_struct ($tokens, $pos) {
    $$pos++; # consume '{'
    my %fields = _parse_struct_fields($tokens, $pos, '}');
    die "Typist::Parser: expected '}'"
        unless $$pos < @$tokens && $tokens->[$$pos] eq '}';
    $$pos++;
    Typist::Type::Struct->new(%fields);
}

# Common struct field parser: IDENT '?'? '=>' type_expr (',' ...)*
sub _parse_struct_fields ($tokens, $pos, $close) {
    my %fields;
    return %fields if $$pos < @$tokens && $tokens->[$$pos] eq $close;

    my $key = $tokens->[$$pos++];
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
        $key = $tokens->[$$pos++];
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
        push @params, _parse_union($tokens, $pos);
        while ($$pos < @$tokens && $tokens->[$$pos] eq ',') {
            $$pos++;
            if ($$pos < @$tokens && $tokens->[$$pos] eq '...') {
                $$pos++;
                $variadic = 1;
            }
            push @params, _parse_union($tokens, $pos);
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

# ── DSL Constructors ─────────────────────────────

# Struct(k => V, ...) → Type::Struct
sub _parse_dsl_struct ($name, $tokens, $pos) {
    $$pos++; # consume '('
    my %fields = _parse_struct_fields($tokens, $pos, ')');
    die "Typist::Parser: expected ')' after Struct(...)"
        unless $$pos < @$tokens && $tokens->[$$pos] eq ')';
    $$pos++;
    Typist::Type::Struct->new(%fields);
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

    # Parse optional effect row: ! Label | Label | var
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
        # Optional bound: A: Num
        if ($$pos < @$tokens && $tokens->[$$pos] eq ':') {
            $$pos++;  # consume ':'
            # Resolve the bound type name
            die "Typist::Parser: expected bound type after ':' in forall"
                unless $$pos < @$tokens;
            $bound = _resolve_name($tokens->[$$pos++]);
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
    my $base = $tok =~ /\./ ? 'Num' : 'Int';
    return Typist::Type::Literal->new($tok + 0, $base);
}

# ── Name Resolution ───────────────────────────────

sub _resolve_name ($name) {
    return Typist::Type::Atom->new($name) if $PRIMITIVES{$name};
    return Typist::Type::Var->new($name)  if $name =~ /\A[A-Z]\z/;
    Typist::Type::Alias->new($name);
}

# ── Effect Row (inline) ─────────────────────────

# Parse an effect row within a function type: Eff(Label | Label | var)
# Requires the Eff(...) wrapper after '!'.
sub _parse_effect_row ($tokens, $pos, $close = undef) {
    die "Typist::Parser: expected 'Eff(' after '!'"
        unless $$pos + 1 < @$tokens
            && $tokens->[$$pos] eq 'Eff'
            && $tokens->[$$pos + 1] eq '(';
    $$pos += 2;  # consume 'Eff' and '('

    my @labels;
    my $row_var;

    while ($$pos < @$tokens && $tokens->[$$pos] ne ')') {
        my $tok = $tokens->[$$pos++];
        if ($tok =~ /\A[a-z]/) {
            $row_var = $tok;
        } else {
            push @labels, $tok;
        }
        last unless $$pos < @$tokens && $tokens->[$$pos] eq '|';
        $$pos++;  # consume '|'
    }

    die "Typist::Parser: expected ')' after Eff(...)"
        unless $$pos < @$tokens && $tokens->[$$pos] eq ')';
    $$pos++;  # consume ')'

    Typist::Type::Row->new(labels => \@labels, row_var => $row_var);
}

# ── Row Parsing ──────────────────────────────────

# Parse a row expression: "Console | State | r"
# Labels are uppercase-initial identifiers; a trailing lowercase identifier is a row variable.
sub parse_row ($class, $expr) {
    my @tokens = grep { $_ ne '' } split /\s*\|\s*/, $expr;
    my (@labels, $row_var);

    for my $i (0 .. $#tokens) {
        my $tok = $tokens[$i];
        $tok =~ s/\A\s+//;
        $tok =~ s/\s+\z//;

        if ($tok =~ /\A[a-z]/) {
            die "Typist::Parser: row variable '$tok' must be the last element in '$expr'"
                unless $i == $#tokens;
            $row_var = $tok;
        } else {
            push @labels, $tok;
        }
    }

    Typist::Type::Row->new(labels => \@labels, row_var => $row_var);
}

# ── Unified Annotation Parsing ──────────────────

# Parse a :Type(...) annotation string.
# Supports: simple types, function types, and generic declarations.
#   "Int"                              → { generics_raw => [], type => Atom(Int) }
#   "(Int, Str) -> Bool"               → { generics_raw => [], type => Func }
#   "<T: Num>(T, T) -> T"              → { generics_raw => ["T: Num"], type => Func }
#   "<T, r: Row>(T) -> Str ! Console | r"
sub parse_annotation ($class, $input) {
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
        @generics_raw = _split_generics_str($gen_str);
        $trimmed = substr($trimmed, $end + 1);
        $trimmed =~ s/\A\s+//;
    }

    # Tokenize and parse the type expression
    my @tokens = _tokenize($trimmed);
    my $pos = 0;
    my $type;

    # Detect function type: starts with '(' and has '->' after matching ')'
    if (@tokens && $tokens[0] eq '(') {
        my $depth = 0;
        my $close_pos;
        for my $i (0 .. $#tokens) {
            $depth++ if $tokens[$i] eq '(';
            if ($tokens[$i] eq ')') {
                $depth--;
                if ($depth == 0) { $close_pos = $i; last; }
            }
        }
        if (defined $close_pos && $close_pos + 1 < @tokens && $tokens[$close_pos + 1] eq '->') {
            $type = _parse_func_type(\@tokens, \$pos);
        }
    }

    $type //= _parse_union(\@tokens, \$pos);

    die "Typist::Parser: unexpected token '$tokens[$pos]' in annotation '$input'"
        if $pos < @tokens;

    +{ generics_raw => \@generics_raw, type => $type };
}

# Split generic declaration string on commas, respecting <> and () nesting.
# Skips '>' that appears as part of '->' (arrow in kind annotations).
sub _split_generics_str ($str) {
    my @result;
    my $current = '';
    my $depth = 0;
    my @chars = split //, $str;

    for my $i (0 .. $#chars) {
        my $ch = $chars[$i];
        if ($ch eq '<' || $ch eq '(') { $depth++ }
        elsif ($ch eq '>' || $ch eq ')') {
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

1;

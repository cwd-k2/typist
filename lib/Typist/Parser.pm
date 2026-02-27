package Typist::Parser;
use v5.40;

use Typist::Type::Atom;
use Typist::Type::Param;
use Typist::Type::Union;
use Typist::Type::Intersection;
use Typist::Type::Func;
use Typist::Type::Struct;
use Typist::Type::Var;
use Typist::Type::Alias;
use Typist::Type::Literal;

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

        if    ($input =~ /\G(->)/gc)              { push @tokens, $1 }
        elsif ($input =~ /\G(=>)/gc)              { push @tokens, $1 }
        elsif ($input =~ /\G("(?:[^"\\]|\\.)*")/gc) { push @tokens, $1 }
        elsif ($input =~ /\G('(?:[^'\\]|\\.)*')/gc) { push @tokens, $1 }
        elsif ($input =~ /\G(-?\d+(?:\.\d+)?)/gc)   { push @tokens, $1 }
        elsif ($input =~ /\G([A-Za-z_]\w*)/gc)    { push @tokens, $1 }
        elsif ($input =~ /\G([\[\]{}(),|&?])/gc)  { push @tokens, $1 }
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

    return _parse_struct($tokens, $pos)  if $tok eq '{';
    return _parse_grouped($tokens, $pos) if $tok eq '(';
    return _parse_literal($tokens, $pos) if $tok =~ /\A["\d'-]/;
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

    my @params;
    my $return_type;

    unless ($$pos < @$tokens && $tokens->[$$pos] eq ']') {
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

    die "Typist::Parser: expected ']' after parameter list"
        unless $$pos < @$tokens && $tokens->[$$pos] eq ']';
    $$pos++;

    # Maybe[T] desugars to T | Undef
    if ($name eq 'Maybe' && @params == 1 && !$return_type) {
        return Typist::Type::Union->new(
            $params[0],
            Typist::Type::Atom->new('Undef'),
        );
    }

    # CodeRef[Args -> Return]
    if ($name eq 'CodeRef' && $return_type) {
        return Typist::Type::Func->new(\@params, $return_type);
    }

    Typist::Type::Param->new($name, @params);
}

# struct ::= '{' (IDENT '?'? '=>' type_expr (',' IDENT '?'? '=>' type_expr)*)? '}'
sub _parse_struct ($tokens, $pos) {
    $$pos++; # consume '{'

    my %fields;
    unless ($$pos < @$tokens && $tokens->[$$pos] eq '}') {
        my $key = $tokens->[$$pos++];
        # Optional marker: key followed by '?'
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
            last if $$pos < @$tokens && $tokens->[$$pos] eq '}';
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
    }

    die "Typist::Parser: expected '}'"
        unless $$pos < @$tokens && $tokens->[$$pos] eq '}';
    $$pos++;

    Typist::Type::Struct->new(%fields);
}

# grouped ::= '(' type_expr ')'
sub _parse_grouped ($tokens, $pos) {
    $$pos++; # consume '('
    my $inner = _parse_union($tokens, $pos);

    die "Typist::Parser: expected ')'"
        unless $$pos < @$tokens && $tokens->[$$pos] eq ')';
    $$pos++;

    $inner;
}

# ── DSL Constructors ─────────────────────────────

# Struct(k => V, ...) → Type::Struct
sub _parse_dsl_struct ($name, $tokens, $pos) {
    $$pos++; # consume '('

    my %fields;
    unless ($$pos < @$tokens && $tokens->[$$pos] eq ')') {
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
            last if $$pos < @$tokens && $tokens->[$$pos] eq ')';
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
    }

    die "Typist::Parser: expected ')' after Struct(...)"
        unless $$pos < @$tokens && $tokens->[$$pos] eq ')';
    $$pos++;

    Typist::Type::Struct->new(%fields);
}

# Func(A, B, returns => R) → Type::Func
sub _parse_dsl_func ($name, $tokens, $pos) {
    $$pos++; # consume '('

    my @params;
    my $return_type;

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

            push @params, _parse_union($tokens, $pos);

            if ($$pos < @$tokens && $tokens->[$$pos] eq ',') {
                $$pos++;
                next;
            }
            last;
        }
    }

    die "Typist::Parser: expected ')' after Func(...)"
        unless $$pos < @$tokens && $tokens->[$$pos] eq ')';
    $$pos++;

    die "Typist::Parser: Func() requires 'returns => Type'"
        unless $return_type;

    Typist::Type::Func->new(\@params, $return_type);
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

    my @params;
    my $return_type;

    unless ($$pos < @$tokens && $tokens->[$$pos] eq ')') {
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

    die "Typist::Parser: expected ')' after $name(...)"
        unless $$pos < @$tokens && $tokens->[$$pos] eq ')';
    $$pos++;

    # Maybe(T) desugars to T | Undef
    if ($name eq 'Maybe' && @params == 1 && !$return_type) {
        return Typist::Type::Union->new(
            $params[0],
            Typist::Type::Atom->new('Undef'),
        );
    }

    # CodeRef(Args -> Return)
    if ($name eq 'CodeRef' && $return_type) {
        return Typist::Type::Func->new(\@params, $return_type);
    }

    Typist::Type::Param->new($name, @params);
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

1;

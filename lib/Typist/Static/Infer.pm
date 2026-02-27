package Typist::Static::Infer;
use v5.40;

use Typist::Type::Atom;
use Typist::Type::Param;
use Typist::Type::Literal;
use Typist::Subtype;

# ── Public API ───────────────────────────────────

# Infer a Typist type from a PPI element (static analysis counterpart of
# Typist::Inference::infer_value).  Returns undef for expressions we cannot
# reason about statically — the caller should skip the check in that case.
sub infer_expr ($class, $element) {
    return undef unless defined $element;

    # ── Numeric literals ────────────────────────
    if ($element->isa('PPI::Token::Number')) {
        return _infer_number($element);
    }

    # ── String literals ─────────────────────────
    if ($element->isa('PPI::Token::Quote')) {
        my $str = $element->can('string') ? $element->string : $element->content;
        return Typist::Type::Literal->new($str, 'Str');
    }
    if ($element->isa('PPI::Token::HereDoc')) {
        return Typist::Type::Atom->new('Str');
    }

    # ── undef keyword ──────────────────────────
    if ($element->isa('PPI::Token::Word') && $element->content eq 'undef') {
        return Typist::Type::Atom->new('Undef');
    }

    # ── Array constructor [...] ─────────────────
    if ($element->isa('PPI::Structure::Constructor') && $element->start->content eq '[') {
        return _infer_array($element);
    }

    # ── Hash constructor {...} with => ──────────
    if ($element->isa('PPI::Structure::Constructor') && $element->start->content eq '{') {
        return _infer_hash($element);
    }

    undef;
}

# ── Number Inference ─────────────────────────────

sub _infer_number ($token) {
    my $content = $token->content;

    # Float / Exp → Num literal
    if ($token->isa('PPI::Token::Number::Float') || $token->isa('PPI::Token::Number::Exp')) {
        return Typist::Type::Literal->new($content + 0, 'Num');
    }

    # 0 or 1 → Bool literal, otherwise → Int literal
    my $val = $content + 0;
    if ($content eq '0' || $content eq '1') {
        return Typist::Type::Literal->new($val, 'Bool');
    }

    Typist::Type::Literal->new($val, 'Int');
}

# ── Array Inference ──────────────────────────────

sub _infer_array ($constructor) {
    # PPI uses PPI::Statement (not ::Expression) inside array constructors
    my $expr = $constructor->find_first('PPI::Statement');
    return Typist::Type::Param->new('ArrayRef', Typist::Type::Atom->new('Any'))
        unless $expr;

    my @elem_types;
    for my $child ($expr->schildren) {
        next if $child->isa('PPI::Token::Operator');   # skip commas
        my $t = __PACKAGE__->infer_expr($child);
        push @elem_types, $t if defined $t;
    }

    return Typist::Type::Param->new('ArrayRef', Typist::Type::Atom->new('Any'))
        unless @elem_types;

    my $common = $elem_types[0];
    for my $i (1 .. $#elem_types) {
        $common = Typist::Subtype->common_super($common, $elem_types[$i]);
    }

    Typist::Type::Param->new('ArrayRef', $common);
}

# ── Hash Inference ───────────────────────────────

sub _infer_hash ($constructor) {
    my $expr = $constructor->find_first('PPI::Statement::Expression')
            // $constructor->find_first('PPI::Statement');
    return undef unless $expr;

    # Must contain => to be recognized as a hash (not a block)
    my $has_fat_comma = $expr->find_first(sub {
        $_[1]->isa('PPI::Token::Operator') && $_[1]->content eq '=>'
    });
    return undef unless $has_fat_comma;

    # Collect value types (every other significant element after =>)
    my @children = $expr->schildren;
    my @val_types;
    my $i = 0;
    while ($i < @children) {
        # key
        $i++;
        # =>
        last if $i >= @children;
        $i++ if $children[$i]->isa('PPI::Token::Operator') && $children[$i]->content eq '=>';
        # value
        last if $i >= @children;
        my $t = __PACKAGE__->infer_expr($children[$i]);
        push @val_types, $t if defined $t;
        $i++;
        # skip comma
        $i++ if $i < @children && $children[$i]->isa('PPI::Token::Operator') && $children[$i]->content eq ',';
    }

    my $str_type = Typist::Type::Atom->new('Str');

    return Typist::Type::Param->new('HashRef', $str_type, Typist::Type::Atom->new('Any'))
        unless @val_types;

    my $common = $val_types[0];
    for my $j (1 .. $#val_types) {
        $common = Typist::Subtype->common_super($common, $val_types[$j]);
    }

    Typist::Type::Param->new('HashRef', $str_type, $common);
}

1;

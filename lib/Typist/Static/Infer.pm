package Typist::Static::Infer;
use v5.40;

use Typist::Type::Atom;
use Typist::Type::Param;
use Typist::Type::Literal;
use Typist::Type::Union;
use Typist::Subtype;

# ── Public API ───────────────────────────────────

# Infer a Typist type from a PPI element (static analysis counterpart of
# Typist::Inference::infer_value).  Returns undef for expressions we cannot
# reason about statically — the caller should skip the check in that case.
sub infer_expr ($class, $element, $env = undef) {
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

    # ── Variable symbol → lookup in type env ────
    if ($element->isa('PPI::Token::Symbol')) {
        return undef unless $env;
        my $var_type = $env->{variables}{$element->content};
        return undef unless $var_type;

        # Subscript access: $sym->[idx] or $sym->{key}
        my $arrow = $element->snext_sibling;
        if ($arrow && $arrow->isa('PPI::Token::Operator') && $arrow->content eq '->') {
            my $subscript = $arrow->snext_sibling;
            if ($subscript && $subscript->isa('PPI::Structure::Subscript')) {
                return _infer_subscript_access($var_type, $subscript);
            }
        }

        return $var_type;
    }

    # ── handle expression: Word("handle") + Block ──
    if ($element->isa('PPI::Token::Word') && $element->content eq 'handle') {
        my $next = $element->snext_sibling;
        if ($next && $next->isa('PPI::Structure::Block')) {
            return _infer_block_return($next, $env);
        }
    }

    # ── match expression: Word("match") + value ────
    if ($element->isa('PPI::Token::Word') && $element->content eq 'match') {
        return _infer_match_return($element, $env);
    }

    # ── Function call: Word followed by List ────
    if ($element->isa('PPI::Token::Word')) {
        my $next = $element->snext_sibling;
        if ($next && $next->isa('PPI::Structure::List')) {
            return _infer_call($element->content, $env, $next);
        }
    }

    # ── Operator expressions (Statement-level) ────
    if ($element->isa('PPI::Statement')
        && !$element->isa('PPI::Statement::Sub')
        && !$element->isa('PPI::Statement::Variable')
        && !$element->isa('PPI::Statement::Compound')
        && !$element->isa('PPI::Statement::Package')
        && !$element->isa('PPI::Statement::Include')
        && !$element->isa('PPI::Statement::Scheduled'))
    {
        return _infer_operator_expr($element, $env);
    }

    undef;
}

# ── Function Call Inference ──────────────────────

sub _infer_call ($name, $env, $list_element = undef) {
    return undef unless $env;

    # Local function with known return type
    if (my $ret = $env->{functions}{$name}) {
        return $ret;
    }

    # Partially annotated (has annotations but no :Returns) → unknown
    return undef if $env->{known} && $env->{known}{$name};

    # Cross-package: Pkg::func → registry lookup
    if ($name =~ /\A(.+)::(\w+)\z/) {
        my ($pkg, $fname) = ($1, $2);
        my $registry = $env->{registry};
        if ($registry) {
            my $sig = $registry->lookup_function($pkg, $fname);
            if ($sig && $sig->{returns}) {
                return _maybe_instantiate_return($sig, $env, $list_element);
            }
            # Registered but no return type → partially annotated
            return undef if $sig;
        }
    }

    # Builtin fallback: CORE::name from prelude or declare
    if (my $registry = $env->{registry}) {
        my $core_sig = $registry->lookup_function('CORE', $name);
        if ($core_sig && $core_sig->{returns}) {
            return $core_sig->{returns};
        }
    }

    # Current-package function (e.g., ADT constructor registered by Analyzer)
    if (my $registry = $env->{registry}) {
        my $pkg = $env->{package} // 'main';
        my $pkg_sig = $registry->lookup_function($pkg, $name);
        if ($pkg_sig && $pkg_sig->{returns}) {
            return _maybe_instantiate_return($pkg_sig, $env, $list_element);
        }
    }

    # Completely unannotated → Any (gradual typing)
    Typist::Type::Atom->new('Any');
}

# For generic functions (incl. GADT constructors), resolve type variables
# in the return type by unifying formal param types against inferred arg types.
sub _maybe_instantiate_return ($sig, $env, $list_element) {
    my $ret = $sig->{returns};
    my $generics = $sig->{generics};

    # No generics or no argument list → return as-is
    return $ret unless $generics && @$generics && $list_element;
    return $ret unless $sig->{params} && @{$sig->{params}};

    # Infer argument types from PPI List
    my @arg_types;
    my $expr = $list_element->schild(0);
    if ($expr && $expr->isa('PPI::Statement::Expression')) {
        for my $child ($expr->schildren) {
            next if $child->isa('PPI::Token::Operator') && $child->content eq ',';
            my $t = __PACKAGE__->infer_expr($child, $env);
            push @arg_types, $t if $t;
        }
    }
    return $ret unless @arg_types;

    # Build bindings by matching formal params against actual arg types
    my %bindings;
    my @params = @{$sig->{params}};
    for my $i (0 .. $#params) {
        last if $i > $#arg_types;
        _collect_bindings($params[$i], $arg_types[$i], \%bindings);
    }
    return $ret unless %bindings;

    # Substitute bindings into return type
    $ret->substitute(\%bindings);
}

# Recursively collect type variable bindings by matching formal vs actual types.
sub _collect_bindings ($formal, $actual, $bindings) {
    if ($formal->is_var) {
        $bindings->{$formal->name} //= $actual;
        return;
    }
    # Param[X] vs Param[Int] → recurse into type args
    if ($formal->is_param && $actual->is_param
        && $formal->base eq $actual->base)
    {
        my @fp = $formal->params;
        my @ap = $actual->params;
        for my $i (0 .. $#fp) {
            last if $i > $#ap;
            _collect_bindings($fp[$i], $ap[$i], $bindings);
        }
    }
}

# ── Block Return Type Inference ─────────────────
#
# Infers the return type of a PPI::Structure::Block by examining
# its last statement.  Used by handle inference.

sub _infer_block_return ($block, $env) {
    my @stmts = grep { $_->isa('PPI::Statement') } $block->schildren;
    return Typist::Type::Atom->new('Void') unless @stmts;

    my $last  = $stmts[-1];
    my $first = $last->schild(0);

    # Explicit return: infer the expression after 'return'
    if ($first && $first->isa('PPI::Token::Word') && $first->content eq 'return') {
        my $val = $first->snext_sibling;
        return Typist::Type::Atom->new('Void')
            unless $val && !($val->isa('PPI::Token::Structure') && $val->content eq ';');
        return __PACKAGE__->infer_expr($val, $env);
    }

    # Implicit return: infer from the last statement's first child
    __PACKAGE__->infer_expr($first, $env) // __PACKAGE__->infer_expr($last, $env);
}

# ── Match Return Type Inference ──────────────────
#
# Walks siblings after `match` to find all handler blocks
# (sub { ... }), infers each handler's return type, then
# computes the union/LUB.

sub _infer_match_return ($match_word, $env) {
    my @arm_types;
    my $sib = $match_word->snext_sibling;

    while ($sib) {
        last if $sib->isa('PPI::Token::Structure') && $sib->content eq ';';

        # Look for Word("sub") followed by optional Prototype then Block
        if ($sib->isa('PPI::Token::Word') && $sib->content eq 'sub') {
            my $after = $sib->snext_sibling;
            # Skip prototype: sub (...) { ... }
            if ($after && $after->isa('PPI::Token::Prototype')) {
                $after = $after->snext_sibling;
            }
            if ($after && $after->isa('PPI::Structure::Block')) {
                my $arm_type = _infer_block_return($after, $env);
                push @arm_types, $arm_type if defined $arm_type;
            }
        }

        $sib = $sib->snext_sibling;
    }

    return undef unless @arm_types;
    return $arm_types[0] if @arm_types == 1;

    # Widen literals to base atoms (consistent with _infer_ternary)
    my @widened = map {
        $_->is_literal ? Typist::Type::Atom->new($_->base_type) : $_
    } @arm_types;

    # LUB
    my $result = $widened[0];
    for my $i (1 .. $#widened) {
        $result = Typist::Subtype->common_super($result, $widened[$i]);
    }

    # If LUB is too coarse (Any), try Union instead
    if ($result->is_atom && $result->name eq 'Any' && @widened <= 4) {
        my %seen;
        my @unique = grep { !$seen{$_->to_string}++ } @widened;
        return @unique == 1 ? $unique[0] : Typist::Type::Union->new(@unique);
    }

    $result;
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

# ── Operator Expression Inference ───────────────

sub _infer_operator_expr ($stmt, $env) {
    my @children = grep { !$_->isa('PPI::Token::Structure') } $stmt->schildren;

    return undef unless @children >= 2;

    # Unary: ! Expr  or  not Expr
    if (@children == 2
        && $children[0]->isa('PPI::Token::Operator')
        && ($children[0]->content eq '!' || $children[0]->content eq 'not'))
    {
        return Typist::Type::Atom->new('Bool');
    }

    # Subscript access: $sym->[idx] or $sym->{key}
    if (@children == 3
        && $children[0]->isa('PPI::Token::Symbol')
        && $children[1]->isa('PPI::Token::Operator') && $children[1]->content eq '->'
        && $children[2]->isa('PPI::Structure::Subscript'))
    {
        if ($env) {
            my $var_type = $env->{variables}{$children[0]->content};
            return _infer_subscript_access($var_type, $children[2]) if $var_type;
        }
        return undef;
    }

    # Binary: Expr Op Expr  (exactly 3 significant children)
    if (@children == 3 && $children[1]->isa('PPI::Token::Operator')) {
        return _infer_binop($children[1]->content, $children[0], $children[2], $env);
    }

    # Ternary: Expr ? Expr : Expr  (exactly 5 significant children)
    if (@children == 5
        && $children[1]->isa('PPI::Token::Operator') && $children[1]->content eq '?'
        && $children[3]->isa('PPI::Token::Operator') && $children[3]->content eq ':')
    {
        return _infer_ternary($children[2], $children[4], $env);
    }

    undef;
}

sub _infer_ternary ($then_expr, $else_expr, $env) {
    my $then_type = __PACKAGE__->infer_expr($then_expr, $env);
    my $else_type = __PACKAGE__->infer_expr($else_expr, $env);

    return undef unless defined $then_type && defined $else_type;

    # Widen literals to base atoms for result typing
    my $then_w = $then_type->is_literal ? Typist::Type::Atom->new($then_type->base_type) : $then_type;
    my $else_w = $else_type->is_literal ? Typist::Type::Atom->new($else_type->base_type) : $else_type;

    # Same type → unify
    return $then_w if $then_w->to_string eq $else_w->to_string;

    # Try LUB via common_super; use Union when LUB is too coarse
    my $lub = Typist::Subtype->common_super($then_w, $else_w);
    return $lub if !($lub->is_atom && $lub->name eq 'Any');

    Typist::Type::Union->new($then_w, $else_w);
}

sub _infer_binop ($op, $lhs, $rhs, $env) {
    # Arithmetic → Num
    return Typist::Type::Atom->new('Num')
        if $op =~ /\A(?:\+|-|\*|\/|%|\*\*)\z/;

    # String concatenation → Str
    return Typist::Type::Atom->new('Str') if $op eq '.';

    # Numeric comparison → Bool
    return Typist::Type::Atom->new('Bool')
        if $op =~ /\A(?:==|!=|<|>|<=|>=|<=>)\z/;

    # String comparison → Bool
    return Typist::Type::Atom->new('Bool')
        if $op =~ /\A(?:eq|ne|lt|gt|le|ge|cmp)\z/;

    # Logical → left operand type
    if ($op =~ /\A(?:&&|\|\||\/\/|and|or)\z/) {
        return __PACKAGE__->infer_expr($lhs, $env);
    }

    undef;
}

# ── Subscript Access Inference ─────────────────

sub _infer_subscript_access ($var_type, $subscript) {
    my $braces = $subscript->braces;

    # Array subscript: $arr->[idx] — ArrayRef[T] → T
    if ($braces eq '[]') {
        if ($var_type->is_param && $var_type->base eq 'ArrayRef') {
            return ($var_type->params)[0];
        }
        return undef;
    }

    # Hash/Struct subscript: $h->{key}
    if ($braces eq '{}') {
        # HashRef[K, V] → V
        if ($var_type->is_param && $var_type->base eq 'HashRef') {
            return ($var_type->params)[1];
        }

        # Struct → field type lookup
        if ($var_type->is_struct) {
            my $key = _extract_subscript_key($subscript);
            return undef unless defined $key;

            # Check required fields, then optional fields
            return $var_type->required_ref->{$key} // $var_type->optional_ref->{$key};
        }
    }

    undef;
}

sub _extract_subscript_key ($subscript) {
    # Find the meaningful token inside { ... } or [ ... ]
    my $inner = $subscript->find_first('PPI::Statement::Expression')
             // $subscript->find_first('PPI::Statement');
    return undef unless $inner;

    my $token = $inner->schild(0);
    return undef unless $token;

    # Bare word: {key}
    return $token->content if $token->isa('PPI::Token::Word');

    # Quoted string: {'key'} or {"key"}
    if ($token->isa('PPI::Token::Quote')) {
        return $token->can('string') ? $token->string : $token->content;
    }

    undef;
}

1;

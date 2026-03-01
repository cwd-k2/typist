package Typist::Static::Infer;
use v5.40;

our $VERSION = '0.01';

use Typist::Type::Atom;
use Typist::Type::Param;
use Typist::Type::Struct;
use Typist::Type::Literal;
use Typist::Type::Union;
use Typist::Subtype;

# ── Public API ───────────────────────────────────

# Infer a Typist type from a PPI element (static analysis counterpart of
# Typist::Inference::infer_value).  Returns undef for expressions we cannot
# reason about statically — the caller should skip the check in that case.
sub infer_expr ($class, $element, $env = undef, $expected = undef) {
    return undef unless defined $element;

    # ── Numeric literals ────────────────────────
    if ($element->isa('PPI::Token::Number')) {
        return _infer_number($element);
    }

    # ── String literals ─────────────────────────
    if ($element->isa('PPI::Token::Quote')) {
        # Interpolated strings (containing $var or @arr) → Str (not literal)
        if ($element->isa('PPI::Token::Quote::Double')
            || $element->isa('PPI::Token::Quote::Interpolate'))
        {
            my $raw = $element->string // $element->content;
            return Typist::Type::Atom->new('Str') if $raw =~ /[\$\@]/;
        }
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
        return _infer_array($element, $env, $expected);
    }

    # ── Hash constructor {...} with => ──────────
    if ($element->isa('PPI::Structure::Constructor') && $element->start->content eq '{') {
        return _infer_hash($element, $env, $expected);
    }

    # ── Unary + before hash constructor: +{...} ──
    if ($element->isa('PPI::Token::Operator') && $element->content eq '+') {
        my $next = $element->snext_sibling;
        if ($next && (
            ($next->isa('PPI::Structure::Constructor') && $next->start->content eq '{')
            || $next->isa('PPI::Structure::Block')
        )) {
            return _infer_hash($next, $env, $expected);
        }
    }

    # ── Variable symbol → lookup in type env ────
    if ($element->isa('PPI::Token::Symbol')) {
        return undef unless $env;
        my $var_type = $env->{variables}{$element->content};
        return undef unless $var_type;

        return _chase_subscript_chain($var_type, $element);
    }

    # ── handle expression: Word("handle") + Block ──
    if ($element->isa('PPI::Token::Word') && $element->content eq 'handle') {
        my $next = $element->snext_sibling;
        if ($next && $next->isa('PPI::Structure::Block')) {
            return _infer_block_return($next, $env, $expected);
        }
    }

    # ── match expression: Word("match") + value ────
    if ($element->isa('PPI::Token::Word') && $element->content eq 'match') {
        return _infer_match_return($element, $env, $expected);
    }

    # ── Function call: Word followed by List ────
    if ($element->isa('PPI::Token::Word')) {
        my $next = $element->snext_sibling;
        if ($next && $next->isa('PPI::Structure::List')) {
            my $result = _infer_call($element->content, $env, $next);
            return _chase_subscript_chain($result, $next) if defined $result;
            return undef;
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
        return _infer_operator_expr($element, $env, $expected);
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

    # Cross-package fallback: Exporter-imported constructors (Regular, Ok, Err, etc.)
    if (my $registry = $env->{registry}) {
        if (my $sig = $registry->search_function_by_name($name)) {
            if ($sig->{returns}) {
                my $ret = _maybe_instantiate_return($sig, $env, $list_element);
                # Only use cross-package result if generics are fully instantiated;
                # unresolved type vars (e.g., Err<T>(Str)->Result[T]) fall through to Any
                return $ret unless $ret->free_vars;
            }
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

sub _infer_block_return ($block, $env, $expected = undef) {
    my @stmts = grep { $_->isa('PPI::Statement') } $block->schildren;
    return Typist::Type::Atom->new('Void') unless @stmts;

    my $last  = $stmts[-1];
    my $first = $last->schild(0);

    # Explicit return: infer the expression after 'return'
    if ($first && $first->isa('PPI::Token::Word') && $first->content eq 'return') {
        my $val = $first->snext_sibling;
        return Typist::Type::Atom->new('Void')
            unless $val && !($val->isa('PPI::Token::Structure') && $val->content eq ';');
        return __PACKAGE__->infer_expr($val, $env, $expected);
    }

    # Implicit return: infer from the last statement's first child
    __PACKAGE__->infer_expr($first, $env, $expected) // __PACKAGE__->infer_expr($last, $env, $expected);
}

# ── Match Return Type Inference ──────────────────
#
# Walks siblings after `match` to find all handler blocks
# (sub { ... }), infers each handler's return type, then
# computes the union/LUB.

sub _infer_match_return ($match_word, $env, $expected = undef) {
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
                my $arm_type = _infer_block_return($after, $env, $expected);
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

sub _infer_array ($constructor, $env = undef, $expected = undef) {
    # PPI uses PPI::Statement (not ::Expression) inside array constructors
    my $expr = $constructor->find_first('PPI::Statement');

    # Empty array: use expected type if available
    unless ($expr) {
        return $expected if $expected && $expected->is_param && $expected->base eq 'ArrayRef';
        return Typist::Type::Param->new('ArrayRef', Typist::Type::Atom->new('Any'));
    }

    # Extract element expected type from ArrayRef[T]
    my $elem_expected = ($expected && $expected->is_param && $expected->base eq 'ArrayRef')
        ? ($expected->params)[0] : undef;

    my @elem_types;
    for my $child ($expr->schildren) {
        next if $child->isa('PPI::Token::Operator');   # skip commas, +
        my $t = __PACKAGE__->infer_expr($child, $env, $elem_expected);
        push @elem_types, $t if defined $t;
    }

    unless (@elem_types) {
        return $expected if $expected && $expected->is_param && $expected->base eq 'ArrayRef';
        return Typist::Type::Param->new('ArrayRef', Typist::Type::Atom->new('Any'));
    }

    my $common = $elem_types[0];
    for my $i (1 .. $#elem_types) {
        $common = Typist::Subtype->common_super($common, $elem_types[$i]);
    }

    # When bottom-up LUB yields Any (e.g., diverse struct literals),
    # prefer the top-down expected element type if all elements conform
    if ($common->is_atom && $common->name eq 'Any' && $elem_expected) {
        my $registry = $env ? $env->{registry} : undef;
        my $all_conform = 1;
        for my $t (@elem_types) {
            unless (Typist::Subtype->is_subtype($t, $elem_expected,
                    $registry ? (registry => $registry) : ())) {
                $all_conform = 0;
                last;
            }
        }
        $common = $elem_expected if $all_conform;
    }

    Typist::Type::Param->new('ArrayRef', $common);
}

# ── Hash Inference ───────────────────────────────

sub _infer_hash ($constructor, $env = undef, $expected = undef) {
    my $expr = $constructor->find_first('PPI::Statement::Expression')
            // $constructor->find_first('PPI::Statement');
    return undef unless $expr;

    # Must contain => to be recognized as a hash (not a block)
    my $has_fat_comma = $expr->find_first(sub {
        $_[1]->isa('PPI::Token::Operator') && $_[1]->content eq '=>'
    });
    return undef unless $has_fat_comma;

    # Resolve alias on expected type (e.g., ReportNode → Struct(...))
    if ($expected && $expected->is_alias && $env && $env->{registry}) {
        my $resolved = $env->{registry}->lookup_type($expected->alias_name);
        $expected = $resolved if $resolved;
    }

    # Build field-level expected types from Struct
    my %field_expected;
    if ($expected && $expected->is_struct) {
        %field_expected = %{$expected->required_ref};
        my $opt = $expected->optional_ref // +{};
        %field_expected = (%field_expected, %$opt);
    }

    # Split children into comma-separated groups to handle multi-token values
    # (e.g., ProductId("WIDGET") = Word + List = 2 tokens)
    my @groups;
    my @current;
    for my $child ($expr->schildren) {
        if ($child->isa('PPI::Token::Operator') && $child->content eq ',') {
            push @groups, [@current] if @current;
            @current = ();
        } else {
            push @current, $child;
        }
    }
    push @groups, [@current] if @current;

    # Process each group as key => value
    my %fields;
    my @val_types;
    my $all_keys_known = 1;

    for my $group (@groups) {
        # Find => in this group
        my $arrow_idx;
        for my $j (0 .. $#$group) {
            if ($group->[$j]->isa('PPI::Token::Operator') && $group->[$j]->content eq '=>') {
                $arrow_idx = $j;
                last;
            }
        }
        next unless defined $arrow_idx && $arrow_idx > 0;

        my $key_name = _extract_hash_key_name($group->[0]);
        $all_keys_known = 0 unless defined $key_name;

        # Value is the first element after =>; infer_expr navigates siblings for multi-token
        my $val_token = $group->[$arrow_idx + 1];
        next unless $val_token;

        my $val_expected = defined $key_name ? $field_expected{$key_name} : undef;
        my $t = __PACKAGE__->infer_expr($val_token, $env, $val_expected);
        if (defined $t) {
            push @val_types, $t;
            $fields{$key_name} = $t if defined $key_name;
        }
    }

    # When all keys are statically known, return Struct
    if ($all_keys_known && %fields) {
        return Typist::Type::Struct->new(%fields);
    }

    # Fallback: HashRef[Str, CommonType]
    my $str_type = Typist::Type::Atom->new('Str');

    return Typist::Type::Param->new('HashRef', $str_type, Typist::Type::Atom->new('Any'))
        unless @val_types;

    my $common = $val_types[0];
    for my $j (1 .. $#val_types) {
        $common = Typist::Subtype->common_super($common, $val_types[$j]);
    }

    Typist::Type::Param->new('HashRef', $str_type, $common);
}

# Extract key name from fat-comma left-hand side (bareword or quoted string)
sub _extract_hash_key_name ($token) {
    return $token->content if $token->isa('PPI::Token::Word');
    if ($token->isa('PPI::Token::Quote')) {
        return $token->can('string') ? $token->string : $token->content;
    }
    undef;
}

# ── Operator Expression Inference ───────────────

sub _infer_operator_expr ($stmt, $env, $expected = undef) {
    my @children = grep { !$_->isa('PPI::Token::Structure') } $stmt->schildren;

    return undef unless @children >= 2;

    # Unary: ! Expr  or  not Expr
    if (@children == 2
        && $children[0]->isa('PPI::Token::Operator')
        && ($children[0]->content eq '!' || $children[0]->content eq 'not'))
    {
        return Typist::Type::Atom->new('Bool');
    }

    # Subscript chain: $sym->{key}, $sym->{a}->{b}, $sym->[0]->{name}
    if (@children >= 3
        && $children[0]->isa('PPI::Token::Symbol')
        && $children[1]->isa('PPI::Token::Operator') && $children[1]->content eq '->'
        && $children[2]->isa('PPI::Structure::Subscript'))
    {
        if ($env) {
            my $var_type = $env->{variables}{$children[0]->content};
            return _chase_subscript_chain($var_type, $children[0]) if $var_type;
        }
        return undef;
    }

    # Function call chain: func()->{key}, func()->[0]->{name}
    if (@children >= 4
        && $children[0]->isa('PPI::Token::Word')
        && $children[1]->isa('PPI::Structure::List')
        && $children[2]->isa('PPI::Token::Operator') && $children[2]->content eq '->'
        && $children[3]->isa('PPI::Structure::Subscript'))
    {
        my $call_type = _infer_call($children[0]->content, $env, $children[1]);
        return _chase_subscript_chain($call_type, $children[1]) if defined $call_type;
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
        return _infer_ternary($children[2], $children[4], $env, $expected);
    }

    # Chained binary: Expr Op Expr Op Expr ... (5+ children, same operator)
    if (@children >= 5) {
        my @ops = grep { $_->isa('PPI::Token::Operator') } @children;
        if (@ops >= 2) {
            my $op = $ops[0]->content;
            my $all_same = !grep { $_->content ne $op } @ops;
            if ($all_same) {
                return _infer_binop($op, $children[0], $children[-1], $env);
            }
        }
    }

    undef;
}

sub _infer_ternary ($then_expr, $else_expr, $env, $expected = undef) {
    my $then_type = __PACKAGE__->infer_expr($then_expr, $env, $expected);
    my $else_type = __PACKAGE__->infer_expr($else_expr, $env, $expected);

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

    # String concatenation / repetition → Str
    return Typist::Type::Atom->new('Str') if $op eq '.' || $op eq '.=' || $op eq 'x';

    # Compound assignment: +=, -=, *=, /= → Num
    return Typist::Type::Atom->new('Num')
        if $op =~ /\A(?:\+=|-=|\*=|\/=|%=|\*\*=)\z/;

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

# ── Subscript Chain Inference ─────────────────
#
# Starting from $start_node, walk forward through siblings looking for
# -> followed by PPI::Structure::Subscript.  For each link, refine the
# type via _infer_subscript_access.  Returns the final refined type.

sub _chase_subscript_chain ($type, $start_node) {
    return $type unless defined $type;

    my $node = $start_node->snext_sibling;
    while ($node) {
        last unless $node->isa('PPI::Token::Operator') && $node->content eq '->';
        my $subscript = $node->snext_sibling;
        last unless $subscript && $subscript->isa('PPI::Structure::Subscript');
        $type = _infer_subscript_access($type, $subscript);
        last unless defined $type;
        $node = $subscript->snext_sibling;
    }

    $type;
}

1;

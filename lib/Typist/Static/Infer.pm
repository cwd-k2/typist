package Typist::Static::Infer;
use v5.40;

our $VERSION = '0.01';

use Typist::Type::Atom;
use Typist::Type::Param;
use Typist::Type::Record;
use Typist::Type::Literal;
use Typist::Type::Union;
use Typist::Subtype;
use Typist::Static::Unify;
use Typist::Static::PPIUtil qw(split_comma_groups);

# ── Submodules (partial-package pattern) ─────────
#
# Each file declares `package Typist::Static::Infer;` and defines
# private subs that resolve within this shared namespace.

require Typist::Static::Infer::Call;
require Typist::Static::Infer::Effect;
require Typist::Static::Infer::Match;
require Typist::Static::Infer::Compound;
require Typist::Static::Infer::Operator;
require Typist::Static::Infer::Chain;
require Typist::Static::Infer::HOF;

# ── Callback Param Collector ─────────────────────
#
# During inference, _enrich_env_with_params records callback parameter
# bindings here.  TypeChecker drains this after analysis for symbol index.
#
# Callback parameter context: scoped via `local` in Analyzer->analyze().
# Reentrant-safe — each analysis pass gets its own context.
our $_CALLBACK_CTX = { params => [], seen => {} };

sub clear_callback_params ($class) { $_CALLBACK_CTX = { params => [], seen => {} } }
sub callback_params       ($class) { [@{$_CALLBACK_CTX->{params}}] }

# ── Public API ───────────────────────────────────

# Infer a Typist type from a PPI element (static analysis counterpart of
# Typist::Inference::infer_value).  Returns undef for expressions we cannot
# reason about statically — the caller should skip the check in that case.
sub infer_expr ($class, $element, $env = undef, $expected = undef) {
    return undef unless defined $element;

    # ── Numeric literals ────────────────────────
    if ($element->isa('PPI::Token::Number')) {
        return _infer_number($element, $expected);
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
    # ── qw() word list ────────────────────────────
    if ($element->isa('PPI::Token::QuoteLike::Words')) {
        return Typist::Type::Param->new('Array', Typist::Type::Atom->new('Str'));
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

    # ── Code reference: \&Package::function or \&local_func ─────
    if ($element->isa('PPI::Token::Cast') && $element->content eq '\\') {
        my $next = $element->snext_sibling;
        if ($next && $next->isa('PPI::Token::Symbol') && $next->content =~ /\A&/) {
            my $sym = $next->content;
            if ($sym =~ /\A&(.+)::(\w+)\z/) {
                my ($pkg, $fname) = ($1, $2);
                if (my $registry = $env && $env->{registry}) {
                    my $sig = $registry->lookup_function($pkg, $fname)
                           // $registry->search_function_by_name($fname);
                    if ($sig && $sig->{params} && $sig->{returns}) {
                        require Typist::Type::Func;
                        return Typist::Type::Func->new(
                            $sig->{params}, $sig->{returns}, $sig->{effects});
                    }
                }
            } elsif ($sym =~ /\A&(\w+)\z/) {
                # Local function reference: \&func_name
                my $fname = $1;
                if (my $registry = $env && $env->{registry}) {
                    my $sig = $registry->search_function_by_name($fname);
                    if ($sig && $sig->{params} && $sig->{returns}) {
                        require Typist::Type::Func;
                        return Typist::Type::Func->new(
                            $sig->{params}, $sig->{returns}, $sig->{effects});
                    }
                }
                # Annotated local function
                if ($env && $env->{functions} && $env->{functions}{$fname}) {
                    return Typist::Type::Atom->new('CodeRef');
                }
                # Unannotated / unresolved → undef for gradual typing
            }
        }
        return undef;
    }

    # ── Variable symbol → lookup in type env ────
    if ($element->isa('PPI::Token::Symbol')) {
        return undef unless $env;
        my $var_type = $env->{variables}{$element->content};

        # $hash{key} → look up %hash in env, apply subscript directly
        if (!$var_type && $element->content =~ /\A\$(.+)/) {
            my $next = $element->snext_sibling;
            if ($next && $next->isa('PPI::Structure::Subscript') && $next->braces eq '{}') {
                if ($element->content eq '$ENV') {
                    return Typist::Type::Union->new(
                        Typist::Type::Atom->new('Str'),
                        Typist::Type::Atom->new('Undef'),
                    );
                }
                my $hash_type = $env->{variables}{'%' . $1};
                if ($hash_type) {
                    return _infer_subscript_access($hash_type, $next);
                }
            }
        }

        return undef unless $var_type;

        return _chase_subscript_chain($var_type, $element, $env);
    }

    # ── handle expression: Word("handle") + Block ──
    if ($element->isa('PPI::Token::Word') && $element->content eq 'handle') {
        my $next = $element->snext_sibling;
        if ($next && $next->isa('PPI::Structure::Block')) {
            _infer_handle_handlers($next, $env);
            return _infer_block_return($next, $env, $expected);
        }
    }

    # ── match expression: Word("match") + value ────
    if ($element->isa('PPI::Token::Word') && $element->content eq 'match') {
        return _infer_match_return($element, $env, $expected);
    }

    # ── Anonymous sub expression: sub [sig] { body } ──
    if ($element->isa('PPI::Token::Word') && $element->content eq 'sub') {
        my $parent = $element->parent;
        unless ($parent && $parent->isa('PPI::Statement::Sub')) {
            return _infer_anon_sub($element, $env, $expected);
        }
    }

    # ── map/grep/sort: Word + Block pattern ─────
    if ($element->isa('PPI::Token::Word')
        && ($element->content eq 'map' || $element->content eq 'grep' || $element->content eq 'sort'))
    {
        my $next = $element->snext_sibling;
        if ($next && $next->isa('PPI::Structure::Block')) {
            my $result = _infer_map_grep_sort($element, $env, $expected);
            return $result if defined $result;
        }
    }

    # ── Function call: Word followed by List ────
    if ($element->isa('PPI::Token::Word')) {
        my $next = $element->snext_sibling;
        if ($next && $next->isa('PPI::Structure::List')) {
            my $result = _infer_call($element->content, $env, $next, $expected);
            if (defined $result) {
                $result = _chase_subscript_chain($result, $next, $env);
                # Check for ternary extension: func(...) ? then : else
                return _check_ternary_extension($result, $next, $env, $expected);
            }
            return undef;
        }
        # scoped 'Effect[T]' — bareword + quote (no parens)
        if ($element->content eq 'scoped'
            && $next && $next->isa('PPI::Token::Quote')) {
            my $arg_str = $next->string;
            if ($arg_str && $arg_str =~ /\A\w+/) {
                return Typist::Type::Atom->new("EffectScope[$arg_str]");
            }
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

# Like infer_expr, but peeks at sibling tokens to detect flat binary
# expressions inside Statement::Variable (e.g., "  " x $indent).
# PPI does NOT wrap the RHS of `my $x = expr op expr;` in a sub-statement,
# so init_node is just the first token after `=`.  This method checks
# for an adjacent operator and delegates to _infer_binop.
sub infer_expr_with_siblings ($class, $element, $env = undef, $expected = undef) {
    return undef unless defined $element;

    # Code reference: \&Package::func — Cast followed by &-sigil Symbol
    if ($element->isa('PPI::Token::Cast') && $element->content eq '\\') {
        return $class->infer_expr($element, $env, $expected);
    }

    if ($element->isa('PPI::Token') && !$element->isa('PPI::Token::Operator')) {
        my $next = $element->snext_sibling;
        if ($next && $next->isa('PPI::Token::Operator')) {
            my $op = $next->content;

            # Ternary: COND ? THEN : ELSE (possibly nested)
            if ($op eq '?') {
                # Include ? itself so _infer_flat_ternary can find it
                my @rest = ($next);
                my $sib = $next->snext_sibling;
                while ($sib) {
                    last if $sib->isa('PPI::Token::Structure');
                    push @rest, $sib;
                    $sib = $sib->snext_sibling;
                }
                if (@rest > 1) {
                    my $result = _infer_flat_ternary(\@rest, $env, undef);
                    return $result if defined $result;
                }
            }

            # Accessor chain + operator: $sym->method OP rhs, $sym->field ? T : E
            if ($op eq '->') {
                my $chain_type = $class->infer_expr($element, $env, $expected);
                my $after_chain = _skip_accessor_chain($element);
                if ($after_chain && $after_chain->isa('PPI::Token::Operator')
                    && $after_chain->content ne '=' && $after_chain->content ne '->'
                    && $after_chain->content ne '=>')
                {
                    my $aop = $after_chain->content;
                    # Ternary directly after chain: $obj->flag ? "yes" : "no"
                    if ($aop eq '?') {
                        my @rest = ($after_chain);
                        my $sib = $after_chain->snext_sibling;
                        while ($sib) {
                            last if $sib->isa('PPI::Token::Structure');
                            push @rest, $sib;
                            $sib = $sib->snext_sibling;
                        }
                        if (@rest > 1) {
                            my $result = _infer_flat_ternary(\@rest, $env, undef);
                            return $result if defined $result;
                        }
                    }
                    my $rhs_start = $after_chain->snext_sibling;
                    if ($rhs_start) {
                        # Ternary extension: chain OP RHS ? THEN : ELSE
                        my $after_rhs = $rhs_start->snext_sibling;
                        if ($after_rhs && $after_rhs->isa('PPI::Token::Operator')
                            && $after_rhs->content eq '?')
                        {
                            my @rest = ($after_rhs);
                            my $sib = $after_rhs->snext_sibling;
                            while ($sib) {
                                last if $sib->isa('PPI::Token::Structure');
                                push @rest, $sib;
                                $sib = $sib->snext_sibling;
                            }
                            if (@rest > 1) {
                                my $result = _infer_flat_ternary(\@rest, $env, undef);
                                return $result if defined $result;
                            }
                        }
                        # Collect all remaining siblings for the RHS
                        my @rest = ($rhs_start);
                        my $sib = $rhs_start->snext_sibling;
                        while ($sib) {
                            last if $sib->isa('PPI::Token::Structure');
                            push @rest, $sib;
                            $sib = $sib->snext_sibling;
                        }
                        my $rt = @rest == 1 ? $class->infer_expr($rest[0], $env)
                                            : _infer_children_slice(\@rest, $env);
                        my $result = _result_type_for_op($aop, $chain_type, $rt, $env);
                        return $result if defined $result;
                    }
                }
                return $chain_type if defined $chain_type;
            }

            if ($op ne '=' && $op ne '->' && $op ne '=>') {
                my $rhs = $next->snext_sibling;
                if ($rhs) {
                    # Check for ternary extension: EXPR OP RHS ? THEN : ELSE
                    my $after_rhs = $rhs->snext_sibling;
                    if ($after_rhs && $after_rhs->isa('PPI::Token::Operator')
                        && $after_rhs->content eq '?')
                    {
                        # Include ? itself so _infer_flat_ternary can find it
                        my @rest = ($after_rhs);
                        my $sib = $after_rhs->snext_sibling;
                        while ($sib) {
                            last if $sib->isa('PPI::Token::Structure');
                            push @rest, $sib;
                            $sib = $sib->snext_sibling;
                        }
                        if (@rest > 1) {
                            my $result = _infer_flat_ternary(\@rest, $env, undef);
                            return $result if defined $result;
                        }
                    }

                    my $result = _infer_binop($op, $element, $rhs, $env);
                    return $result if defined $result;
                }
            }
        }
    }

    # Function call + operator: func(args) OP rhs (e.g., length($s) > 0)
    if ($element->isa('PPI::Token::Word') && !$element->isa('PPI::Token::Operator')) {
        my $next = $element->snext_sibling;
        if ($next && $next->isa('PPI::Structure::List')) {
            my $after_list = $next->snext_sibling;
            if ($after_list && $after_list->isa('PPI::Token::Operator')) {
                my $op = $after_list->content;
                # Ternary after function call: defined($s) ? THEN : ELSE
                if ($op eq '?') {
                    my @all = ($element, $next, $after_list);
                    my $sib = $after_list->snext_sibling;
                    while ($sib) {
                        last if $sib->isa('PPI::Token::Structure');
                        push @all, $sib;
                        $sib = $sib->snext_sibling;
                    }
                    if (@all > 3) {
                        my $result = _infer_flat_ternary(\@all, $env, $expected);
                        return $result if defined $result;
                    }
                }
                if ($op ne '=' && $op ne '->' && $op ne '=>' && $op ne '?') {
                    my $rhs = $after_list->snext_sibling;
                    if ($rhs) {
                        return _infer_binop($op, $element, $rhs, $env);
                    }
                }
            }
        }
    }

    $class->infer_expr($element, $env, $expected);
}

# Infer the **container** type of a list-assignment RHS (before array deref).
# For `@{func()}` returns the return type of func(); for `@$ref` returns ref's type.
# Used by TypeChecker to distribute Tuple elements to individual list variables.
sub infer_list_rhs_type ($class, $init_node, $env) {
    return undef unless defined $init_node && $env;

    # Pattern 1: Cast('@') + Block → @{EXPR}
    if ($init_node->isa('PPI::Token::Cast') && $init_node->content eq '@') {
        my $next = $init_node->snext_sibling;
        if ($next && $next->isa('PPI::Structure::Block')) {
            my @inner = $next->schildren;
            my $inner_expr = $inner[0];
            @inner = $inner_expr->schildren if $inner_expr && $inner_expr->isa('PPI::Statement');

            # @{func()} — Word + List inside block
            if (@inner >= 2 && $inner[0]->isa('PPI::Token::Word')
                && $inner[1]->isa('PPI::Structure::List'))
            {
                return _infer_call($inner[0]->content, $env, $inner[1]);
            }
            # @{$var->method} or @{$ref} — general expression inside block
            if (@inner >= 1) {
                return $class->infer_expr($inner[0], $env);
            }
        }
        # Pattern 2: Cast('@') + Symbol → @$ref
        if ($next && $next->isa('PPI::Token::Symbol')) {
            return _lookup_var($next->content, $env);
        }
    }

    # Pattern 3: Word + List → func() direct call
    if ($init_node->isa('PPI::Token::Word')) {
        my $next = $init_node->snext_sibling;
        if ($next && $next->isa('PPI::Structure::List')) {
            return _infer_call($init_node->content, $env, $next);
        }
        # Pattern 3b: scoped 'Effect[T]' → bareword + quote (no parens)
        if ($init_node->content eq 'scoped'
            && $next && $next->isa('PPI::Token::Quote')) {
            my $arg_str = $next->string;
            if ($arg_str && $arg_str =~ /\A\w+/) {
                return Typist::Type::Atom->new("EffectScope[$arg_str]");
            }
        }
    }

    # Pattern 4: List literal (...) → Tuple from element-wise inference
    if ($init_node->isa('PPI::Structure::List')) {
        my $expr = $init_node->find_first('PPI::Statement::Expression')
                // $init_node->find_first('PPI::Statement');
        if ($expr) {
            my @elems;
            for my $child ($expr->schildren) {
                next if $child->isa('PPI::Token::Operator') && $child->content eq ',';
                push @elems, $class->infer_expr($child, $env);
            }
            if (@elems && grep { defined } @elems) {
                require Typist::Type::Param;
                return Typist::Type::Param->new('Tuple',
                    map { $_ // Typist::Type::Atom->new('Any') } @elems);
            }
        }
    }

    # Fallback: general expression inference
    $class->infer_expr_with_siblings($init_node, $env);
}

# ── Block Return Type Inference ─────────────────
#
# Infers the return type of a PPI::Structure::Block by examining
# its last statement.  Used by handle, match, and anonymous sub inference.

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

    # Implicit return: try statement-level first (catches ternary/binary),
    # then fall back to first-child (catches match/handle/function calls).
    __PACKAGE__->infer_expr($last, $env, $expected) // __PACKAGE__->infer_expr($first, $env, $expected);
}

# ── Number Inference ─────────────────────────────

sub _infer_number ($token, $expected = undef) {
    my $content = $token->content;

    # Float / Exp → Double literal
    if ($token->isa('PPI::Token::Number::Float') || $token->isa('PPI::Token::Number::Exp')) {
        return Typist::Type::Literal->new($content + 0, 'Double');
    }

    # 0 or 1 → Int literal (default), Bool only when expected is Bool
    my $val = $content + 0;
    if ($content eq '0' || $content eq '1') {
        my $base = ($expected && $expected->is_atom && $expected->name eq 'Bool')
            ? 'Bool' : 'Int';
        return Typist::Type::Literal->new($val, $base);
    }

    Typist::Type::Literal->new($val, 'Int');
}

# ── Iterable Element Type Inference ────────────────
#
# Given a PPI::Structure::List from `for my $var (LIST)`, infer the element
# type of the iterable expression.  Supports:
#   @$ref         → ArrayRef unwrap
#   @array        → ArrayRef unwrap via $array lookup
#   $ref          → ArrayRef unwrap
#   func(...)     → ArrayRef unwrap on return type
#   $obj->m->@*   → accessor chain + postfix deref

sub infer_iterable_element_type ($class, $list_node, $env = undef) {
    return undef unless $list_node && $env;

    # Unwrap List → Expression (PPI returns '' not undef on no-match)
    my $expr = $list_node->find_first('PPI::Statement::Expression')
            || $list_node->find_first('PPI::Statement');
    return undef unless $expr;

    my @children = $expr->schildren;
    return undef unless @children;

    # Pattern 1: @$ref — Cast('@') + Symbol('$ref')
    if (@children >= 2
        && $children[0]->isa('PPI::Token::Cast') && $children[0]->content eq '@'
        && $children[1]->isa('PPI::Token::Symbol'))
    {
        my $var_name = $children[1]->content;
        my $var_type = _lookup_var($var_name, $env);
        return _unwrap_arrayref($var_type) if $var_type;
    }

    # Pattern 2: @array — Symbol('@array') → lookup as @array or $array
    if (@children == 1 && $children[0]->isa('PPI::Token::Symbol')
        && $children[0]->raw_type eq '@')
    {
        my $arr_name = $children[0]->content;
        # Try @-sigil first (annotated arrays: my @arr :sig(Array[T]))
        my $var_type = _lookup_var($arr_name, $env);
        unless ($var_type) {
            # Fallback: $-sigil (scalar ref variables: my $ref :sig(ArrayRef[T]))
            (my $scalar_name = $arr_name) =~ s/\A\@/\$/;
            $var_type = _lookup_var($scalar_name, $env);
        }
        return _unwrap_arrayref($var_type) if $var_type;
    }

    # Pattern 3: $obj->method->@* or $var->@* — accessor chain with postfix deref
    if (@children >= 3
        && $children[0]->isa('PPI::Token::Symbol')
        && $children[0]->raw_type eq '$')
    {
        # Check if the chain ends with ->@*
        my $last = $children[-1];
        my $penult = @children >= 2 ? $children[-2] : undef;
        if ($last->isa('PPI::Token::Cast') && $last->content eq '@*'
            && $penult && $penult->isa('PPI::Token::Operator') && $penult->content eq '->')
        {
            # Chase the chain excluding the trailing ->@*
            my $var_type = _lookup_var($children[0]->content, $env);
            if ($var_type) {
                my $chain_type = _chase_subscript_chain($var_type, $children[0], $env);
                return _unwrap_arrayref($chain_type) if $chain_type;
            }
        }
    }

    # Pattern 4: single $ref — Symbol → ArrayRef unwrap
    if (@children == 1 && $children[0]->isa('PPI::Token::Symbol')
        && $children[0]->raw_type eq '$')
    {
        my $var_type = _lookup_var($children[0]->content, $env);
        return _unwrap_arrayref($var_type) if $var_type;
    }

    # Pattern 5: func(...) — Word + List → function return type → ArrayRef unwrap
    if (@children >= 2
        && $children[0]->isa('PPI::Token::Word')
        && $children[1]->isa('PPI::Structure::List'))
    {
        my $ret = _infer_call($children[0]->content, $env, $children[1]);
        return _unwrap_arrayref($ret) if $ret;
    }

    # Pattern 6: range expression — 0..$#arr, 0..5, "a".."z"
    if (@children >= 3) {
        for my $ci (0 .. $#children) {
            if ($children[$ci]->isa('PPI::Token::Operator') && $children[$ci]->content eq '..') {
                my $lhs = $ci > 0 ? $children[$ci - 1] : undef;
                my $rhs = $ci < $#children ? $children[$ci + 1] : undef;
                # Both sides numeric (Number, $#arr, or numeric variable) → Int
                my $lhs_num = $lhs && ($lhs->isa('PPI::Token::Number')
                    || ($lhs->isa('PPI::Token::ArrayIndex')));
                my $rhs_num = $rhs && ($rhs->isa('PPI::Token::Number')
                    || ($rhs->isa('PPI::Token::ArrayIndex'))
                    || ($rhs->isa('PPI::Token::Cast') && $rhs->content eq '$#'));
                return Typist::Type::Atom->new('Int') if $lhs_num && $rhs_num;
                # String range: "a".."z" → Str
                my $lhs_str = $lhs && $lhs->isa('PPI::Token::Quote');
                my $rhs_str = $rhs && $rhs->isa('PPI::Token::Quote');
                return Typist::Type::Atom->new('Str') if $lhs_str && $rhs_str;
                last;
            }
        }
    }

    # Pattern 7: @{$expr} — Cast('@') + Block → extract symbol from block → unwrap
    if (@children >= 2
        && $children[0]->isa('PPI::Token::Cast') && $children[0]->content eq '@'
        && $children[1]->isa('PPI::Structure::Block'))
    {
        my $block = $children[1];
        my @inner = $block->schildren;
        my $inner_expr = $inner[0];
        @inner = $inner_expr->schildren if $inner_expr && $inner_expr->isa('PPI::Statement');
        if (@inner >= 1 && $inner[0]->isa('PPI::Token::Symbol') && $inner[0]->raw_type eq '$') {
            my $var_type = _lookup_var($inner[0]->content, $env);
            return _unwrap_arrayref($var_type) if $var_type;
        }
    }

    undef;
}

# Extract element type T from ArrayRef[T] or Array[T].
sub _unwrap_arrayref ($type) {
    return undef unless defined $type;
    return ($type->params)[0] if $type->is_param && ($type->base eq 'ArrayRef' || $type->base eq 'Array');
    undef;
}

# Look up a variable type in the env.
sub _lookup_var ($name, $env) {
    return undef unless $env && $env->{variables};
    $env->{variables}{$name};
}

1;

__END__

=head1 NAME

Typist::Static::Infer - Static type inference from PPI elements

=head1 DESCRIPTION

Infers L<Typist::Type> objects from PPI syntax nodes without executing code.
Handles literals, variables, operators, function calls, anonymous subs,
C<handle>/C<match> expressions, and bidirectional propagation from expected types.

=head2 infer_expr

    my $type = Typist::Static::Infer->infer_expr($ppi_element, $env, $expected);

Infer a Typist type from a single PPI element.  Returns C<undef> for
expressions that cannot be statically resolved.  C<$env> is an optional
hashref mapping variable/function names to types; C<$expected> is an optional
type for bidirectional propagation into arrays, hashes, ternary arms, and
anonymous sub parameters.

=head2 infer_expr_with_siblings

    my $type = Typist::Static::Infer->infer_expr_with_siblings($element, $env);

Like C<infer_expr>, but also inspects the element's right sibling for a binary
operator.  Use this for initializer expressions where PPI does not wrap the
right-hand side in a sub-statement (e.g. C<my $x = "  " x $indent>).

=head2 infer_iterable_element_type

    my $elem_type = Typist::Static::Infer->infer_iterable_element_type($list_node, $env);

Given the PPI list node of a C<for> loop's iterable expression, infer the
element type.  Supports C<@$ref>, C<@array>, bare C<$ref>, function calls,
and accessor chains with postfix dereference (C<< $obj->method->@* >>).

=head2 clear_callback_params

    Typist::Static::Infer->clear_callback_params;

Reset the internal callback parameter accumulator.  Called at the start of
each L<Typist::Static::TypeChecker> analysis pass.

=cut

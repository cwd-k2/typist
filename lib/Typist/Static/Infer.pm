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

# ── Operator Tables ─────────────────────────────

my %OP_PRECEDENCE = (
    'or' => 1, 'xor' => 1,  'and' => 2,
    '||' => 3, '//'  => 3,  '&&'  => 4,
    '=~' => 5, '!~'  => 5,
    '==' => 6, '!='  => 6, '<=>' => 6,
    '<'  => 6, '>'   => 6, '<='  => 6, '>=' => 6,
    'eq' => 6, 'ne'  => 6, 'cmp' => 6,
    'lt' => 6, 'gt'  => 6, 'le'  => 6, 'ge' => 6,
    '+'  => 7, '-'   => 7, '.'   => 7,
    '*'  => 8, '/'   => 8, '%'   => 8, 'x'  => 8,
    '**' => 9,
);
my %NUMERIC_ATOM = map { $_ => 1 } qw(Bool Int Double Num);

# ── Callback Param Collector ─────────────────────
#
# During inference, _enrich_env_with_params records callback parameter
# bindings here.  TypeChecker drains this after analysis for symbol index.
#
# NOTE: These are global (class-level) state, cleared at the start of each
# analysis pass via clear_callback_params(). This is safe because:
#   - Perl LSP server is single-threaded (sequential message dispatch)
#   - Analyzer->analyze() calls clear_callback_params() before analysis

my @_CALLBACK_PARAMS;
my %_CALLBACK_PARAMS_SEEN;

sub clear_callback_params ($class) { @_CALLBACK_PARAMS = (); %_CALLBACK_PARAMS_SEEN = () }
sub callback_params       ($class) { [@_CALLBACK_PARAMS] }

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

    # ── Code reference: \&Package::function ─────
    if ($element->isa('PPI::Token::Cast') && $element->content eq '\\') {
        my $next = $element->snext_sibling;
        if ($next && $next->isa('PPI::Token::Symbol') && $next->content =~ /\A&(.+)::(\w+)\z/) {
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
        }
        return undef;
    }

    # ── Variable symbol → lookup in type env ────
    if ($element->isa('PPI::Token::Symbol')) {
        return undef unless $env;
        my $var_type = $env->{variables}{$element->content};
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
sub infer_expr_with_siblings ($class, $element, $env = undef) {
    return undef unless defined $element;

    # Code reference: \&Package::func — Cast followed by &-sigil Symbol
    if ($element->isa('PPI::Token::Cast') && $element->content eq '\\') {
        return $class->infer_expr($element, $env);
    }

    if ($element->isa('PPI::Token') && !$element->isa('PPI::Token::Operator')) {
        my $next = $element->snext_sibling;
        if ($next && $next->isa('PPI::Token::Operator')) {
            my $op = $next->content;
            if ($op ne '=' && $op ne '->' && $op ne '=>') {
                my $rhs = $next->snext_sibling;
                if ($rhs) {
                    my $result = _infer_binop($op, $element, $rhs, $env);
                    return $result if defined $result;
                }
            }
        }
    }

    $class->infer_expr($element, $env);
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
    }

    # Fallback: general expression inference
    $class->infer_expr_with_siblings($init_node, $env);
}

# ── Function Call Inference ──────────────────────

sub _infer_call ($name, $env, $list_element = undef, $expected = undef) {
    return undef unless $env;

    # Local function with known return type
    if (my $ret = $env->{functions}{$name}) {
        # Generic local functions: instantiate via registry sig when args present
        if ($ret->free_vars && $list_element && $env->{registry}) {
            my $pkg = $env->{package} // 'main';
            my $sig = $env->{registry}->lookup_function($pkg, $name);
            if ($sig && $sig->{generics} && @{$sig->{generics}}) {
                return _maybe_instantiate_return($sig, $env, $list_element, $expected);
            }
        }
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
                return _maybe_instantiate_return($sig, $env, $list_element, $expected);
            }
            # Registered but no return type → partially annotated
            return undef if $sig;
        }
    }

    # Builtin fallback: CORE::name from prelude or declare
    if (my $registry = $env->{registry}) {
        my $core_sig = $registry->lookup_function('CORE', $name);
        if ($core_sig && $core_sig->{returns}) {
            return $core_sig->{generics} && @{$core_sig->{generics}}
                ? _maybe_instantiate_return($core_sig, $env, $list_element, $expected)
                : $core_sig->{returns};
        }
    }

    # Current-package function (e.g., ADT constructor registered by Analyzer)
    if (my $registry = $env->{registry}) {
        my $pkg = $env->{package} // 'main';
        my $pkg_sig = $registry->lookup_function($pkg, $name);
        if ($pkg_sig && $pkg_sig->{returns}) {
            return _maybe_instantiate_return($pkg_sig, $env, $list_element, $expected);
        }
    }

    # Cross-package fallback: Exporter-imported constructors (Regular, Ok, Err, etc.)
    if (my $registry = $env->{registry}) {
        if (my $sig = $registry->search_function_by_name($name)) {
            if ($sig->{returns}) {
                my $ret = _maybe_instantiate_return($sig, $env, $list_element, $expected);
                # Bidirectional: bind remaining free vars from expected type.
                # Handles: None() -> Option[T] with expected Option[Str] → Option[Str]
                if ($ret->free_vars && $expected) {
                    my %extra;
                    if (Typist::Static::Unify->collect_bindings($ret, $expected, \%extra) && %extra) {
                        $ret = $ret->substitute(\%extra);
                    }
                }
                # Replace remaining unresolved type vars with '_' placeholder.
                if ($ret->free_vars) {
                    require Typist::Type::Fold;
                    $ret = Typist::Type::Fold->map_type($ret, sub ($t) {
                        $t->is_var ? Typist::Type::Atom->new('_') : $t;
                    });
                }
                return $ret;
            }
        }
    }

    # Completely unannotated → Any (gradual typing)
    Typist::Type::Atom->new('Any');
}

# For generic functions (incl. GADT constructors), resolve type variables
# in the return type by unifying formal param types against inferred arg types.
sub _maybe_instantiate_return ($sig, $env, $list_element, $expected = undef) {
    my $ret = $sig->{returns};
    my $generics = $sig->{generics};

    # No generics or no argument list → return as-is
    return $ret unless $generics && @$generics && $list_element;

    # Generic struct constructor: named-arg binding
    if ($sig->{struct_constructor} && $ret->is_struct && $ret->type_params) {
        return _instantiate_generic_struct($ret, $env, $list_element, $expected);
    }

    return $ret unless $sig->{params} && @{$sig->{params}};

    # Extract PPI argument nodes
    # PPI wraps argument lists as Statement::Expression (multi-arg) or
    # plain Statement (single complex arg like [...]/{...}).
    # Anonymous subs are split by PPI into sub + Prototype + Block;
    # we keep only the 'sub' token and skip its continuations, since
    # infer_expr(sub_token) walks snext_sibling internally.
    my @arg_nodes;
    my $expr = $list_element->schild(0);
    if ($expr && $expr->isa('PPI::Statement')) {
        my @children = $expr->schildren;
        my $i = 0;
        while ($i <= $#children) {
            my $child = $children[$i];
            if ($child->isa('PPI::Token::Operator') && $child->content eq ',') {
                $i++; next;
            }
            push @arg_nodes, $child;
            # Skip anonymous sub continuations (Prototype/List + Block)
            if ($child->isa('PPI::Token::Word') && $child->content eq 'sub'
                && !($child->parent && $child->parent->isa('PPI::Statement::Sub'))) {
                $i++;
                # Skip signature (Prototype or List)
                if ($i <= $#children && ($children[$i]->isa('PPI::Token::Prototype')
                                      || $children[$i]->isa('PPI::Structure::List'))) {
                    $i++;
                }
                # Skip block
                if ($i <= $#children && $children[$i]->isa('PPI::Structure::Block')) {
                    $i++;
                }
                next;
            }
            # Skip function call argument list: Word + List forms a single call.
            # infer_expr(Word) follows snext_sibling to discover the List.
            if ($child->isa('PPI::Token::Word') && $child->content ne 'sub'
                && $i + 1 <= $#children
                && $children[$i + 1]->isa('PPI::Structure::List'))
            {
                $i += 2;
                next;
            }
            $i++;
        }
    }
    return $ret unless @arg_nodes;

    my @params = @{$sig->{params}};
    my %bindings;

    # Pass 1: infer all args without expected, collect initial bindings
    for my $i (0 .. $#params) {
        last if $i > $#arg_nodes;
        my $t = __PACKAGE__->infer_expr($arg_nodes[$i], $env);
        if ($t) {
            Typist::Static::Unify->collect_bindings($params[$i], $t, \%bindings);
        }
    }

    # Pass 2: re-infer callback args with substituted formal type as expected.
    # Activates when Pass 1 produced bindings, OR when there are Func params
    # (bidirectional inference can discover bindings from callback bodies even
    # when Pass 1 failed — e.g., kleisli(sub { ... }, sub { ... })).
    my $has_func_params = grep { $_->is_func } @params;
    if (%bindings || $has_func_params) {
        for my $i (0 .. $#params) {
            last if $i > $#arg_nodes;
            next unless $params[$i]->is_func;
            my $expected = $params[$i]->substitute(\%bindings);
            my $refined = __PACKAGE__->infer_expr($arg_nodes[$i], $env, $expected);
            if ($refined) {
                Typist::Static::Unify->collect_bindings(
                    $params[$i], $refined, \%bindings);
            }
        }
    }

    my $result = %bindings ? $ret->substitute(\%bindings) : $ret;
    my $any_bound = !!%bindings;

    # Pass 3: bind remaining free vars from expected type (bidirectional).
    # This handles cases like Err("msg") -> Result[T] where T can't be
    # bound from arguments but CAN be bound from the expected return type.
    # Guard: only when result and expected share the same Param base,
    # to avoid incorrect binding like Expr[A] + Int → Expr[Int].
    if ($expected && $result->free_vars
        && $result->is_param && $expected->is_param
        && "${\$result->base}" eq "${\$expected->base}") {
        my %extra;
        if (Typist::Static::Unify->collect_bindings($result, $expected, \%extra) && %extra) {
            $result = $ret->substitute(+{ %bindings, %extra });
            $any_bound = 1;
        }
    }

    # Fallback: replace remaining free vars with placeholder '_'.
    # Only when at least one binding was made — if nothing was bound,
    # preserve live Vars so TypeChecker can detect type mismatches.
    if ($result->free_vars && $any_bound) {
        require Typist::Type::Fold;
        $result = Typist::Type::Fold->map_type($result, sub ($t) {
            $t->is_var ? Typist::Type::Atom->new('_') : $t;
        });
    }

    $result;
}

# Instantiate a generic struct constructor from named arguments.
# Extracts key => value pairs from PPI, infers value types, and
# collects bindings from formal field types.
sub _instantiate_generic_struct ($struct_type, $env, $list_element, $expected = undef) {
    my $record = $struct_type->record;
    my $req = $record->required_ref;
    my $opt = $record->optional_ref;
    my %all = (%$req, %$opt);

    # Extract key => value pairs from the PPI List
    my $expr = $list_element->schild(0);
    $expr = $expr->schild(0) if $expr && $expr->isa('PPI::Statement::Expression')
                              && $expr->schildren == 1
                              && $expr->schild(0)->isa('PPI::Structure::List');
    return $struct_type unless $expr;

    # Get the expression node (may be inside Statement::Expression)
    my $target = $expr;
    if ($target->isa('PPI::Statement::Expression')) {
        # Use it directly — children are the tokens
    } elsif ($target->isa('PPI::Structure::List')) {
        $target = $target->schild(0) // return $struct_type;
    }

    # Split into comma-separated groups and collect bindings
    my %bindings;
    my @children = $target->schildren;
    my @current;
    for my $child (@children) {
        if ($child->isa('PPI::Token::Operator') && $child->content eq ',') {
            _bind_struct_field(\@current, \%all, \%bindings, $env) if @current;
            @current = ();
        } else {
            push @current, $child;
        }
    }
    _bind_struct_field(\@current, \%all, \%bindings, $env) if @current;

    # Widen literal bindings: Literal(42, Int) → Atom(Int)
    for my $k (keys %bindings) {
        my $v = $bindings{$k};
        if ($v->is_literal) {
            my $base = $v->base_type;
            $base = 'Int' if $base eq 'Bool';
            $bindings{$k} = Typist::Type::Atom->new($base);
        }
    }

    # Substitute bindings into the struct type
    if (%bindings) {
        my @tp = $struct_type->type_params;
        my @type_args = map {
            $bindings{$_} // Typist::Type::Atom->new('_')
        } @tp;
        return $struct_type->substitute(\%bindings)->instantiate(@type_args)
            if @tp;
    }

    $struct_type;
}

# Helper: extract field name and value from a key => value group,
# infer the value type, and collect bindings.
sub _bind_struct_field ($group, $all_fields, $bindings, $env) {
    # Find => in this group
    my $arrow_idx;
    for my $j (0 .. $#$group) {
        if ($group->[$j]->isa('PPI::Token::Operator') && $group->[$j]->content eq '=>') {
            $arrow_idx = $j;
            last;
        }
    }
    return unless defined $arrow_idx && $arrow_idx > 0;

    my $key_tok = $group->[0];
    my $field_name;
    if ($key_tok->isa('PPI::Token::Word')) {
        $field_name = $key_tok->content;
    } elsif ($key_tok->isa('PPI::Token::Quote')) {
        $field_name = $key_tok->string;
    }
    return unless defined $field_name && exists $all_fields->{$field_name};

    my $val_token = $group->[$arrow_idx + 1] // return;
    my $formal = $all_fields->{$field_name};
    my $inferred = __PACKAGE__->infer_expr($val_token, $env, $formal);
    return unless $inferred;

    Typist::Static::Unify->collect_bindings($formal, $inferred, $bindings);
}

# ── Handle Handler Type Propagation ─────────────
#
# Walks siblings after the handle BODY block to find effect handler
# maps (Effect => +{ op => sub (...) { ... } }) and propagates
# operation types into anonymous sub parameters via _infer_anon_sub.

sub _infer_handle_handlers ($body_block, $env) {
    my $registry = ($env // +{})->{registry} // return;
    my $sib = $body_block->snext_sibling;
    my $current_effect;

    while ($sib) {
        last if $sib->isa('PPI::Token::Structure') && $sib->content eq ';';

        # Effect name: Word followed by =>
        if ($sib->isa('PPI::Token::Word')) {
            my $after = $sib->snext_sibling;
            if ($after && $after->isa('PPI::Token::Operator') && $after->content eq '=>') {
                $current_effect = $sib->content;
            }
        }

        # Handler map: Constructor +{...}
        if ($sib->isa('PPI::Structure::Constructor') && $current_effect) {
            _infer_handler_map($sib, $current_effect, $env);
        }

        $sib = $sib->snext_sibling;
    }
}

sub _infer_handler_map ($constructor, $effect_name, $env) {
    my $registry = $env->{registry} // return;
    my $expr = $constructor->find_first('PPI::Statement::Expression') // return;
    my $current_op;

    for my $child ($expr->schildren) {
        # Track op name: Word (not 'sub') followed by =>
        if ($child->isa('PPI::Token::Word') && $child->content ne 'sub') {
            my $after = $child->snext_sibling;
            if ($after && $after->isa('PPI::Token::Operator') && $after->content eq '=>') {
                $current_op = $child->content;
            }
        }

        # Found anonymous sub for the current op
        if ($child->isa('PPI::Token::Word') && $child->content eq 'sub' && $current_op) {
            my $sig = $registry->lookup_function($effect_name, $current_op);
            if ($sig && $sig->{params}) {
                my $expected = Typist::Type::Func->new(
                    $sig->{params}, $sig->{returns} // Typist::Type::Atom->new('Any'),
                );
                _infer_anon_sub($child, $env, $expected);
            }
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

    # Implicit return: try statement-level first (catches ternary/binary),
    # then fall back to first-child (catches match/handle/function calls).
    __PACKAGE__->infer_expr($last, $env, $expected) // __PACKAGE__->infer_expr($first, $env, $expected);
}

# ── Data Type Resolution ─────────────────────────
#
# Resolves an inferred type to a Data definition + type variable bindings.
# Returns ($data_def, \%bindings) or (undef, undef).

sub _resolve_data_type ($type, $env) {
    return (undef, undef) unless $type && $env && $env->{registry};
    my $registry = $env->{registry};

    # Direct Data object (rare in static analysis, but possible)
    if ($type->is_data) {
        my $dt = $registry->lookup_datatype($type->name);
        return (undef, undef) unless $dt;
        my %bindings;
        my @params = $dt->type_params;
        my @args   = $type->type_args;
        for my $i (0 .. $#params) {
            $bindings{$params[$i]} = $args[$i] if $i <= $#args && $args[$i];
        }
        return ($dt, \%bindings);
    }

    # Param type: Result[Int] → base 'Result', params [Int]
    if ($type->is_param) {
        my $base_name = $type->base;
        $base_name = "$base_name" if ref $base_name;
        my $dt = $registry->lookup_datatype($base_name);
        return (undef, undef) unless $dt;
        my %bindings;
        my @params     = $dt->type_params;
        my @type_args  = $type->params;
        for my $i (0 .. $#params) {
            $bindings{$params[$i]} = $type_args[$i] if $i <= $#type_args && $type_args[$i];
        }
        return ($dt, \%bindings);
    }

    # Alias: resolve through registry, recurse
    if ($type->is_alias) {
        my $resolved = eval { $registry->lookup_type($type->alias_name) };
        if ($resolved && !$resolved->is_alias) {
            return _resolve_data_type($resolved, $env);
        }
    }

    # Atom: non-parameterized ADT (e.g., Shape, OrderStatus)
    if ($type->is_atom) {
        my $dt = $registry->lookup_datatype($type->name);
        return ($dt, +{}) if $dt;
    }

    (undef, undef);
}

# Build expected Func type for a match arm callback from variant definition.
sub _build_match_arm_expected ($data_def, $tag, $bindings, $outer_expected) {
    return undef unless $data_def && $tag;
    return undef if $tag eq '_';

    my $variants = $data_def->variants;
    return undef unless $variants && exists $variants->{$tag};

    my @variant_types = @{$variants->{$tag}};
    return undef unless @variant_types;

    # Substitute type variable bindings for parameterized ADTs
    if ($bindings && %$bindings) {
        @variant_types = map { $_->substitute($bindings) } @variant_types;
    }

    my $ret = $outer_expected // Typist::Type::Atom->new('Any');
    Typist::Type::Func->new(\@variant_types, $ret);
}

# ── Match Return Type Inference ──────────────────
#
# Walks siblings after `match` to find all handler blocks
# (sub { ... }), infers each handler's return type, then
# computes the union/LUB.  When the matched value resolves
# to a Data type, propagates variant inner types to arm callbacks.

sub _infer_match_return ($match_word, $env, $expected = undef) {
    # Infer matched value type and resolve to Data definition
    my $val_sib = $match_word->snext_sibling;
    my ($data_def, $bindings);

    if ($val_sib && $env) {
        my $val_type = __PACKAGE__->infer_expr($val_sib, $env);
        ($data_def, $bindings) = _resolve_data_type($val_type, $env) if $val_type;
    }

    my @arm_types;
    my $sib = $match_word->snext_sibling;
    my $current_tag;

    while ($sib) {
        last if $sib->isa('PPI::Token::Structure') && $sib->content eq ';';

        # Track current tag: Word(TagName) or Magic(_) followed by =>
        # PPI parses `_` as PPI::Token::Magic (special filehandle),
        # so we must also check for it as the match fallback arm.
        if (($sib->isa('PPI::Token::Word') && $sib->content ne 'sub')
            || ($sib->isa('PPI::Token::Magic') && $sib->content eq '_'))
        {
            my $after_tag = $sib->snext_sibling;
            if ($after_tag && $after_tag->isa('PPI::Token::Operator') && $after_tag->content eq '=>') {
                $current_tag = $sib->content;
            }
        }

        # Look for Word("sub") followed by optional signature then Block
        if ($sib->isa('PPI::Token::Word') && $sib->content eq 'sub') {
            my $after = $sib->snext_sibling;
            # Skip signature: PPI::Token::Prototype or PPI::Structure::List
            if ($after && ($after->isa('PPI::Token::Prototype')
                        || $after->isa('PPI::Structure::List')))
            {
                $after = $after->snext_sibling;
            }
            if ($after && $after->isa('PPI::Structure::Block')) {
                my $arm_expected;
                if ($data_def && $current_tag) {
                    $arm_expected = _build_match_arm_expected(
                        $data_def, $current_tag, $bindings, $expected,
                    );
                }

                my $arm_type;
                if ($arm_expected) {
                    # Use _infer_anon_sub to get full bidirectional inference
                    my $func = _infer_anon_sub($sib, $env, $arm_expected);
                    $arm_type = $func->returns if $func && $func->is_func;
                } else {
                    $arm_type = _infer_block_return($after, $env, $expected);
                }
                push @arm_types, $arm_type if defined $arm_type;
            }
        }

        $sib = $sib->snext_sibling;
    }

    return undef unless @arm_types;
    return $arm_types[0] if @arm_types == 1;

    # If $expected is available, check if all arms conform to it.
    # Check original types first (preserves literal precision for union expected types),
    # then fall back to widened types (for atom expected types like Int, Str).
    if ($expected) {
        my $registry = $env ? $env->{registry} : undef;
        my @sub_args = $registry ? (registry => $registry) : ();
        my $all_conform = 1;
        for my $t (@arm_types) {
            unless (Typist::Subtype->is_subtype($t, $expected, @sub_args)
                    || ($t->is_literal && Typist::Subtype->is_subtype(
                        Typist::Type::Atom->new($t->base_type), $expected, @sub_args))) {
                $all_conform = 0;
                last;
            }
        }
        return $expected if $all_conform;
    }

    # Widen literals to base atoms (consistent with _infer_ternary)
    my @widened = map {
        $_->is_literal ? Typist::Type::Atom->new($_->base_type) : $_
    } @arm_types;

    # LUB
    my $result = $widened[0];
    for my $i (1 .. $#widened) {
        $result = Typist::Subtype->common_super($result, $widened[$i]);
    }

    # If LUB has free vars and $expected is available, prefer $expected
    if ($expected && $result->free_vars) {
        my $registry = $env ? $env->{registry} : undef;
        my $all_ok = 1;
        for my $t (@widened) {
            unless (Typist::Subtype->is_subtype($t, $expected,
                    $registry ? (registry => $registry) : ())) {
                $all_ok = 0;
                last;
            }
        }
        return $expected if $all_ok;
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

# ── Array Inference ──────────────────────────────

sub _infer_array ($constructor, $env = undef, $expected = undef) {
    # Resolve alias on expected type (e.g., IntList → Union(Int, ArrayRef[IntList]))
    if ($expected && $expected->is_alias && $env && $env->{registry}) {
        my $resolved = $env->{registry}->lookup_type($expected->alias_name);
        $expected = $resolved if $resolved;
    }

    # PPI uses PPI::Statement (not ::Expression) inside array constructors
    my $expr = $constructor->find_first('PPI::Statement');

    # Empty array: use expected type if available
    unless ($expr) {
        return $expected if $expected && $expected->is_param
            && ($expected->base eq 'ArrayRef' || $expected->base eq 'Tuple');
        return Typist::Type::Param->new('ArrayRef', Typist::Type::Atom->new('Any'));
    }

    # Tuple expected: position-based inference
    if ($expected && $expected->is_param && $expected->base eq 'Tuple') {
        my @tuple_expected = $expected->params;
        # Collect non-operator children as elements
        my @children = $expr->schildren;
        my @elems;
        my $has_spread = 0;
        my $ci = 0;
        while ($ci <= $#children) {
            my $child = $children[$ci];
            if ($child->isa('PPI::Token::Operator')) { $ci++; next }
            # Spread or map/grep/sort → not a fixed-length tuple
            if ($child->isa('PPI::Token::Cast') && $child->content eq '@') {
                $has_spread = 1; last;
            }
            if ($child->isa('PPI::Token::Word')
                && ($child->content eq 'map' || $child->content eq 'grep' || $child->content eq 'sort'))
            {
                $has_spread = 1; last;
            }
            # Anonymous sub coalescing: sub + Prototype/List + Block → single element
            if ($child->isa('PPI::Token::Word') && $child->content eq 'sub') {
                push @elems, $child;
                $ci++;
                while ($ci <= $#children) {
                    last unless $children[$ci]->isa('PPI::Token::Prototype')
                             || $children[$ci]->isa('PPI::Structure::List')
                             || $children[$ci]->isa('PPI::Structure::Block');
                    $ci++;
                }
                next;
            }
            # Function call coalescing: Word + List → single element
            if ($child->isa('PPI::Token::Word') && $ci + 1 <= $#children
                && $children[$ci + 1]->isa('PPI::Structure::List'))
            {
                push @elems, $child;
                $ci += 2;
                next;
            }
            push @elems, $child;
            $ci++;
        }
        # Arity match and no spread → position-based inference
        if (!$has_spread && @elems == @tuple_expected) {
            my @inferred;
            for my $idx (0 .. $#elems) {
                my $t = __PACKAGE__->infer_expr($elems[$idx], $env, $tuple_expected[$idx]);
                push @inferred, $t // $tuple_expected[$idx];
            }
            return Typist::Type::Param->new('Tuple', @inferred);
        }
        # Fallback: arity mismatch or spread → treat as ArrayRef
    }

    # Extract element expected type from ArrayRef[T] or Union containing ArrayRef[T]
    my $elem_expected;
    if ($expected && $expected->is_param && $expected->base eq 'ArrayRef') {
        $elem_expected = ($expected->params)[0];
    } elsif ($expected && $expected->is_union) {
        for my $member ($expected->members) {
            if ($member->is_param && $member->base eq 'ArrayRef') {
                $elem_expected = ($member->params)[0];
                last;
            }
        }
    }

    # Single-expression array (no commas): infer the whole Statement as one element.
    # Handles complex expressions like [$p->method >= 5000 ? "a" : "b"]
    # where child-by-child iteration would only see the first token.
    my @children = $expr->schildren;
    my $has_comma = grep { $_->isa('PPI::Token::Operator') && $_->content eq ',' } @children;
    if (!$has_comma && @children > 1) {
        my $t = __PACKAGE__->infer_expr($expr, $env, $elem_expected);
        if (defined $t) {
            $t = ($t->params)[0] if $t->is_param && $t->base eq 'Array';
            $t = Typist::Type::Atom->new($t->base_type) if $t->is_literal;
            return Typist::Type::Param->new('ArrayRef', $t);
        }
    }

    my @elem_types;
    my $i = 0;
    while ($i <= $#children) {
        my $child = $children[$i];
        if ($child->isa('PPI::Token::Operator')) { $i++; next }  # skip commas, +

        # Detect map/grep/sort { BLOCK } LIST — consume the entire pattern
        if ($child->isa('PPI::Token::Word')
            && ($child->content eq 'map' || $child->content eq 'grep' || $child->content eq 'sort'))
        {
            my $t = __PACKAGE__->infer_expr($child, $env, $elem_expected);
            if (defined $t && $t->is_param && $t->base eq 'Array') {
                push @elem_types, ($t->params)[0];
                # Skip siblings consumed by map/grep/sort (block + source list)
                $i++;
                while ($i <= $#children) {
                    last if $children[$i]->isa('PPI::Token::Operator')
                         && $children[$i]->content eq ',';
                    $i++;
                }
                next;
            }
        }

        # @{$expr} or @$var — array dereference spread inside array constructor
        if ($child->isa('PPI::Token::Cast') && $child->content eq '@') {
            my $next_child = $children[$i + 1] // undef;
            # @{BLOCK} form
            if ($next_child && $next_child->isa('PPI::Structure::Block')) {
                my $inner = $next_child->find_first('PPI::Statement');
                if ($inner) {
                    my $first = $inner->schild(0);
                    if ($first) {
                        my $ref_type = __PACKAGE__->infer_expr($first, $env);
                        if ($ref_type) {
                            my $elem = _unwrap_arrayref($ref_type);
                            push @elem_types, $elem if $elem;
                        }
                    }
                }
                $i += 2;  # skip both Cast and Block
                next;
            }
            # @$var form
            if ($next_child && $next_child->isa('PPI::Token::Symbol')) {
                my $var_type = _lookup_var($next_child->content, $env);
                if ($var_type) {
                    my $elem = _unwrap_arrayref($var_type);
                    push @elem_types, $elem if $elem;
                }
                $i += 2;  # skip both Cast and Symbol
                next;
            }
        }

        my $t = __PACKAGE__->infer_expr($child, $env, $elem_expected);
        $i++;
        next unless defined $t;
        # Flatten list types: Array[T] inside [...] contributes T, not Array[T]
        if ($t->is_param && $t->base eq 'Array') {
            push @elem_types, ($t->params)[0];
        } else {
            push @elem_types, $t;
        }
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
    if ($expected && $expected->is_record) {
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
        return Typist::Type::Record->new(%fields);
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

    # Ternary pre-check: if any child is `?`, this is a ternary expression.
    # Must be checked before subscript/method chain patterns which would
    # greedily match the condition part (e.g., $p->stock > 0 ? ... : ...).
    if (@children >= 5
        && grep { $_->isa('PPI::Token::Operator') && $_->content eq '?' } @children)
    {
        # Simple ternary: exactly 5 children
        if (@children == 5
            && $children[1]->isa('PPI::Token::Operator') && $children[1]->content eq '?'
            && $children[3]->isa('PPI::Token::Operator') && $children[3]->content eq ':')
        {
            return _infer_ternary($children[2], $children[4], $env, $expected);
        }
        my $result = _infer_flat_ternary(\@children, $env, $expected);
        return $result if defined $result;
    }

    # Unary: ! Expr  or  not Expr
    if (@children == 2
        && $children[0]->isa('PPI::Token::Operator')
        && ($children[0]->content eq '!' || $children[0]->content eq 'not'))
    {
        return Typist::Type::Atom->new('Bool');
    }

    # Subscript/method chain: $sym->{key}, $sym->method, $sym->{a}->{b}
    if (@children >= 3
        && $children[0]->isa('PPI::Token::Symbol')
        && $children[1]->isa('PPI::Token::Operator') && $children[1]->content eq '->'
        && ($children[2]->isa('PPI::Structure::Subscript') || $children[2]->isa('PPI::Token::Word')))
    {
        if ($env) {
            my $var_type = $env->{variables}{$children[0]->content};
            return _chase_subscript_chain($var_type, $children[0], $env) if $var_type;
        }
        return undef;
    }

    # CodeRef application: $f->(...) where $f :: (A) -> B
    if (@children >= 3
        && $children[0]->isa('PPI::Token::Symbol')
        && $children[1]->isa('PPI::Token::Operator') && $children[1]->content eq '->'
        && $children[2]->isa('PPI::Structure::List'))
    {
        if ($env) {
            my $var_type = $env->{variables}{$children[0]->content};
            return _chase_subscript_chain($var_type, $children[0], $env) if $var_type;
        }
        return undef;
    }

    # Function call chain: func()->{key}, func()->method, func()->[0]->{name}
    if (@children >= 4
        && $children[0]->isa('PPI::Token::Word')
        && $children[1]->isa('PPI::Structure::List')
        && $children[2]->isa('PPI::Token::Operator') && $children[2]->content eq '->'
        && ($children[3]->isa('PPI::Structure::Subscript') || $children[3]->isa('PPI::Token::Word')))
    {
        my $call_type = _infer_call($children[0]->content, $env, $children[1]);
        return _chase_subscript_chain($call_type, $children[1], $env) if defined $call_type;
        return undef;
    }

    # Binary: Expr Op Expr  (exactly 3 significant children)
    if (@children == 3 && $children[1]->isa('PPI::Token::Operator')) {
        return _infer_binop($children[1]->content, $children[0], $children[2], $env);
    }

    # Chained/mixed binary: Expr Op Expr Op Expr ... (5+ children)
    # Handles both same-operator chains and mixed operators (e.g., >= && <=)
    if (@children >= 5) {
        my $result = _infer_children_slice(\@children, $env);
        return $result if defined $result;
    }

    undef;
}

# Infer a ternary branch slice (tokens between ? and : or after :).
# Handles: single token, function call (Word + List), nested ternary.
sub _infer_branch_slice ($slice, $env, $expected) {
    return undef unless $slice && @$slice;
    if (@$slice == 1) {
        return __PACKAGE__->infer_expr($slice->[0], $env, $expected);
    }
    # Check for nested ternary (has ? operator)
    my $has_ternary = grep { $_->isa('PPI::Token::Operator') && $_->content eq '?' } @$slice;
    if ($has_ternary) {
        return _infer_flat_ternary($slice, $env, $expected);
    }
    # Multi-token: infer from first element (PPI sibling chain handles Word+List etc.)
    return __PACKAGE__->infer_expr($slice->[0], $env, $expected);
}

# ── Mixed-Operator Helpers ──────────────────────
# Split a flat expression at the lowest-precedence operator and recurse.

# Find the index of the lowest-precedence operator in @children.
sub _find_split_point ($children) {
    my ($best_idx, $best_prec);
    for my $i (0 .. $#$children) {
        next unless $children->[$i]->isa('PPI::Token::Operator');
        my $op = $children->[$i]->content;
        my $prec = $OP_PRECEDENCE{$op} // next;
        if (!defined $best_prec || $prec <= $best_prec) {
            $best_prec = $prec;
            $best_idx  = $i;
        }
    }
    $best_idx;
}

# Determine result type from operator category and operand types.
# Operand types may be undef (unknown); result is determined by operator category.
sub _result_type_for_op ($op, $lt, $rt) {
    # Comparison → Bool (regardless of operand types)
    return Typist::Type::Atom->new('Bool')
        if $op =~ /\A(?:==|!=|<|>|<=|>=|<=>|eq|ne|lt|gt|le|ge|cmp|=~|!~)\z/;
    # Logical → left operand type (undef if left is unknown)
    return $lt if $op =~ /\A(?:&&|\|\||\/\/|and|or|xor)\z/;
    # Arithmetic → LUB of numeric atoms, fallback Num
    if ($op =~ /\A(?:\+|-|\*|\/|%|\*\*)\z/) {
        my $lw = $lt && $lt->is_literal ? Typist::Type::Atom->new($lt->base_type) : $lt;
        my $rw = $rt && $rt->is_literal ? Typist::Type::Atom->new($rt->base_type) : $rt;
        if ($lw && $rw && $lw->is_atom && $rw->is_atom
            && $NUMERIC_ATOM{$lw->name} && $NUMERIC_ATOM{$rw->name})
        {
            return Typist::Subtype->common_super($lw, $rw);
        }
        return Typist::Type::Atom->new('Num');
    }
    # String → Str
    return Typist::Type::Atom->new('Str') if $op eq '.' || $op eq 'x';
    undef;
}

# Recursively infer a flat children slice by splitting at lowest-precedence op.
sub _infer_children_slice ($children, $env) {
    return undef unless $children && @$children;
    # Single element → infer directly
    return __PACKAGE__->infer_expr($children->[0], $env) if @$children == 1;
    # 3 elements (simple binary) → _infer_binop
    if (@$children == 3 && $children->[1]->isa('PPI::Token::Operator')) {
        return _infer_binop($children->[1]->content, $children->[0], $children->[2], $env);
    }
    # 5+ elements → split at lowest-precedence operator
    my $split = _find_split_point($children);
    return undef unless defined $split && $split > 0 && $split < $#$children;
    my @left  = @$children[0 .. $split - 1];
    my @right = @$children[$split + 1 .. $#$children];
    my $lt = _infer_children_slice(\@left,  $env);
    my $rt = _infer_children_slice(\@right, $env);
    _result_type_for_op($children->[$split]->content, $lt, $rt);
}

# Check for ternary extension after a function call or subscript chain.
# Walks past any -> chains from $after_node, then checks for ? then : else.
# Returns the ternary type if found, otherwise returns $result unchanged.
sub _check_ternary_extension ($result, $after_node, $env, $expected) {
    # Walk past -> chains to find what comes after
    my $node = $after_node->snext_sibling;
    while ($node && $node->isa('PPI::Token::Operator') && $node->content eq '->') {
        my $next = $node->snext_sibling or last;
        # Skip -> Subscript, -> Word, -> List
        if ($next->isa('PPI::Structure::List')) {
            $node = $next->snext_sibling;
            next;
        }
        $node = $next->snext_sibling;
    }
    # Check for ? then : else
    if ($node && $node->isa('PPI::Token::Operator') && $node->content eq '?') {
        my $then_expr = $node->snext_sibling;
        my $colon = $then_expr ? $then_expr->snext_sibling : undef;
        if ($colon && $colon->isa('PPI::Token::Operator') && $colon->content eq ':') {
            my $else_expr = $colon->snext_sibling;
            return _infer_ternary($then_expr, $else_expr, $env, $expected) if $else_expr;
        }
    }
    $result;
}

# Handle nested ternary from a flat PPI children list.
# PPI flattens `Cond ? Then : Cond2 ? Then2 : Else` into a single list.
# Finds the first ? and its matching :, then recurses for nested else branches.
sub _infer_flat_ternary ($children, $env, $expected) {
    # Find first ? operator
    my $q_idx;
    for my $i (0 .. $#$children) {
        if ($children->[$i]->isa('PPI::Token::Operator') && $children->[$i]->content eq '?') {
            $q_idx = $i;
            last;
        }
    }
    return undef unless defined $q_idx;

    # Find matching : (depth-counted for nested ternary)
    my ($depth, $c_idx) = (0, undef);
    for my $i ($q_idx + 1 .. $#$children) {
        if ($children->[$i]->isa('PPI::Token::Operator')) {
            if    ($children->[$i]->content eq '?') { $depth++ }
            elsif ($children->[$i]->content eq ':') {
                if ($depth == 0) { $c_idx = $i; last }
                $depth--;
            }
        }
    }
    return undef unless defined $c_idx;

    # Then: tokens between ? and :
    my @then_slice = @$children[$q_idx + 1 .. $c_idx - 1];
    return undef unless @then_slice;
    my $then_type = _infer_branch_slice(\@then_slice, $env, $expected);

    # Else: everything after :
    my @else_slice = @$children[$c_idx + 1 .. $#$children];
    my $else_type = _infer_branch_slice(\@else_slice, $env, $expected);

    return undef unless defined $then_type && defined $else_type;
    _infer_ternary_types($then_type, $else_type, $env, $expected);
}

sub _infer_ternary ($then_expr, $else_expr, $env, $expected = undef) {
    my $then_type = __PACKAGE__->infer_expr($then_expr, $env, $expected);
    my $else_type = __PACKAGE__->infer_expr($else_expr, $env, $expected);
    return undef unless defined $then_type && defined $else_type;
    _infer_ternary_types($then_type, $else_type, $env, $expected);
}

# Combine two branch types from a ternary expression.
# Shared logic for both simple and nested ternary.
sub _infer_ternary_types ($then_type, $else_type, $env, $expected = undef) {
    # If expected type is available, check if both branches conform (before widening)
    if ($expected) {
        my $registry = $env ? $env->{registry} : undef;
        my @sub_args = $registry ? (registry => $registry) : ();
        if (Typist::Subtype->is_subtype($then_type, $expected, @sub_args)
            && Typist::Subtype->is_subtype($else_type, $expected, @sub_args)) {
            return $expected;
        }
    }

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

# Infer arithmetic result type from operand types.
# If both sides are numeric atoms, LUB preserves precision (Int+Int→Int).
# Falls back to Num when either side is unknown.
sub _infer_arithmetic ($lhs, $rhs, $env) {
    my $lt = __PACKAGE__->infer_expr($lhs, $env);
    my $rt = __PACKAGE__->infer_expr($rhs, $env);
    # Widen literals to base atom
    $lt = Typist::Type::Atom->new($lt->base_type) if $lt && $lt->is_literal;
    $rt = Typist::Type::Atom->new($rt->base_type) if $rt && $rt->is_literal;
    if ($lt && $rt && $lt->is_atom && $rt->is_atom
        && $NUMERIC_ATOM{$lt->name} && $NUMERIC_ATOM{$rt->name})
    {
        return Typist::Subtype->common_super($lt, $rt);
    }
    Typist::Type::Atom->new('Num');
}

sub _infer_binop ($op, $lhs, $rhs, $env) {
    # Arithmetic → LUB of operand types (Int+Int→Int, Int+Double→Double, etc.)
    return _infer_arithmetic($lhs, $rhs, $env)
        if $op =~ /\A(?:\+|-|\*|\/|%|\*\*)\z/;

    # String concatenation / repetition → Str
    return Typist::Type::Atom->new('Str') if $op eq '.' || $op eq '.=' || $op eq 'x';

    # Compound assignment: +=, -=, *=, /= → LUB
    return _infer_arithmetic($lhs, $rhs, $env)
        if $op =~ /\A(?:\+=|-=|\*=|\/=|%=|\*\*=)\z/;

    # Numeric comparison → Bool
    return Typist::Type::Atom->new('Bool')
        if $op =~ /\A(?:==|!=|<|>|<=|>=|<=>)\z/;

    # String comparison → Bool
    return Typist::Type::Atom->new('Bool')
        if $op =~ /\A(?:eq|ne|lt|gt|le|ge|cmp)\z/;

    # Regex match → Bool
    return Typist::Type::Atom->new('Bool')
        if $op eq '=~' || $op eq '!~';

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
        if ($var_type->is_record) {
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

sub _chase_subscript_chain ($type, $start_node, $env = undef) {
    return $type unless defined $type;

    my $node = $start_node->snext_sibling;
    while ($node) {
        last unless $node->isa('PPI::Token::Operator') && $node->content eq '->';
        my $next = $node->snext_sibling;
        last unless $next;

        # -> Subscript: $h->{key}, $a->[0]
        if ($next->isa('PPI::Structure::Subscript')) {
            $type = _infer_subscript_access($type, $next);
            last unless defined $type;
            $node = $next->snext_sibling;
            next;
        }

        # -> Word: method call / struct accessor
        if ($next->isa('PPI::Token::Word')) {
            $type = _infer_method_access($type, $next, $env);
            last unless defined $type;
            # Apply accessor narrowing from defined() guards
            if ($env && $env->{narrowed_accessors}
                && $start_node->isa('PPI::Token::Symbol')) {
                my $var_name = $start_node->content;
                my $acc_name = $next->content;
                if (my $narrowed = $env->{narrowed_accessors}{$var_name}{$acc_name}) {
                    $type = $narrowed;
                }
            }
            # Skip past optional argument list: ->method(...)
            my $after = $next->snext_sibling;
            if ($after && $after->isa('PPI::Structure::List')) {
                $node = $after->snext_sibling;
            } else {
                $node = $after;
            }
            next;
        }

        # -> List: CodeRef application $f->(args)
        if ($next->isa('PPI::Structure::List') && $type->is_func) {
            if ($type->free_vars) {
                my @params = $type->params;
                my %bindings;
                my @arg_nodes;
                my $expr = $next->schild(0);
                if ($expr && $expr->isa('PPI::Statement')) {
                    my @children = $expr->schildren;
                    my $ci = 0;
                    while ($ci <= $#children) {
                        my $child = $children[$ci];
                        if ($child->isa('PPI::Token::Operator') && $child->content eq ',') {
                            $ci++; next;
                        }
                        push @arg_nodes, $child;
                        if ($child->isa('PPI::Token::Word') && $child->content eq 'sub'
                            && !($child->parent && $child->parent->isa('PPI::Statement::Sub'))) {
                            $ci++;
                            if ($ci <= $#children && ($children[$ci]->isa('PPI::Token::Prototype')
                                                   || $children[$ci]->isa('PPI::Structure::List'))) {
                                $ci++;
                            }
                            if ($ci <= $#children && $children[$ci]->isa('PPI::Structure::Block')) {
                                $ci++;
                            }
                            next;
                        }
                        # Skip function call argument list
                        if ($child->isa('PPI::Token::Word') && $child->content ne 'sub'
                            && $ci + 1 <= $#children
                            && $children[$ci + 1]->isa('PPI::Structure::List'))
                        {
                            $ci += 2;
                            next;
                        }
                        $ci++;
                    }
                }

                # Pass 1: infer all args without expected, collect bindings
                for my $i (0 .. $#params) {
                    last if $i > $#arg_nodes;
                    my $t = __PACKAGE__->infer_expr($arg_nodes[$i], $env);
                    Typist::Static::Unify->collect_bindings($params[$i], $t, \%bindings) if $t;
                }

                # Pass 2: re-infer callback args with substituted expected type
                if (%bindings) {
                    for my $i (0 .. $#params) {
                        last if $i > $#arg_nodes;
                        next unless $params[$i]->is_func;
                        my $expected = $params[$i]->substitute(\%bindings);
                        my $refined = __PACKAGE__->infer_expr($arg_nodes[$i], $env, $expected);
                        if ($refined) {
                            Typist::Static::Unify->collect_bindings(
                                $params[$i], $refined, \%bindings);
                        }
                    }
                }

                $type = %bindings ? $type->returns->substitute(\%bindings) : $type->returns;
            } else {
                $type = $type->returns;
            }
            # Naked type vars (e.g. B from HKT foldr) can't be resolved → bail out.
            # But parameterized types with free vars (e.g. Result[B]) are kept:
            # their outer structure is concrete and useful for inference.
            return undef if $type->is_var;
            $node = $next->snext_sibling;
            next;
        }

        last;
    }

    $type;
}

# Infer the return type of a method call or struct accessor.
# For struct types, field accessors return the field type.
# For with(), returns the same struct type.
sub _infer_method_access ($receiver_type, $method_word, $env = undef) {
    my $method_name = $method_word->content;

    # Resolve alias to concrete type (e.g., Alias("Customer") → Struct)
    my $resolved = $receiver_type;
    if ($resolved->is_alias && $env && $env->{registry}) {
        my $looked_up = $env->{registry}->lookup_type($resolved->alias_name);
        $resolved = $looked_up if $looked_up;
    }

    # Newtype: no instance methods
    if ($resolved->is_newtype) {
        return undef;
    }

    # Struct accessor: resolve field type from the inner record
    if ($resolved->is_struct) {
        my $record = $resolved->record;
        my $req = $record->required_ref;
        my $opt = $record->optional_ref;

        my $field_type;
        if (exists $req->{$method_name}) {
            $field_type = $req->{$method_name};
        } elsif (exists $opt->{$method_name}) {
            $field_type = Typist::Type::Union->new(
                $opt->{$method_name}, Typist::Type::Atom->new('Undef'),
            );
        }
        if ($field_type) {
            # Generic struct: substitute type_params → type_args
            if ($resolved->type_params && $resolved->type_args) {
                my @tp = $resolved->type_params;
                my @ta = $resolved->type_args;
                if (@tp == @ta) {
                    my %bindings;
                    $bindings{$tp[$_]} = $ta[$_] for 0 .. $#tp;
                    $field_type = $field_type->substitute(\%bindings);
                }
            }
            return $field_type;
        }

    }

    # Fallback: look up method in registry if available
    if ($env && $env->{registry}) {
        my $pkg = ref $resolved && $resolved->is_struct
            ? $resolved->package : undef;
        if ($pkg) {
            my $sig = $env->{registry}->lookup_method($pkg, $method_name);
            return $sig->{returns} if $sig && $sig->{returns};
        }
    }

    undef;
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

    # Pattern 2: @array — Symbol('@array') → lookup as $array
    if (@children == 1 && $children[0]->isa('PPI::Token::Symbol')
        && $children[0]->raw_type eq '@')
    {
        my $scalar_name = $children[0]->content;
        $scalar_name =~ s/\A\@/\$/;
        my $var_type = _lookup_var($scalar_name, $env);
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

    # Pattern 6: @{$expr} — Cast('@') + Block → extract symbol from block → unwrap
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

# ── Map/Grep/Sort Inference ───────────────────────
#
# map { BLOCK } @list → Array[ReturnType]   (list type, not reference)
# grep { BLOCK } @list → Array[ElemType]
# sort { BLOCK } @list → Array[ElemType]

sub _infer_map_grep_sort ($word, $env, $expected = undef) {
    my $name = $word->content;
    my $next = $word->snext_sibling;
    return undef unless $next && $next->isa('PPI::Structure::Block');

    my $block = $next;

    # Infer source list element type from siblings after the block
    my $elem_type = _infer_source_element_type_after($block, $env);

    # Record $_ binding as callback param for LSP visibility.
    # sort uses $a/$b, not $_ — skip callback param registration for sort.
    if ($elem_type && $name ne 'sort') {
        my $block_line  = $block->line_number;
        my $block_last  = $block->last_element;
        my $block_end   = $block_last ? $block_last->line_number : $block_line;
        my $dedup_key   = '$_:' . $block_line;
        unless ($_CALLBACK_PARAMS_SEEN{$dedup_key}++) {
            my ($topic_line, $topic_col) = ($block_line, $block->column_number + 2);
            my $magics = $block->find('PPI::Token::Magic');
            if ($magics) {
                for my $m (@$magics) {
                    if ($m->content eq '$_') {
                        ($topic_line, $topic_col) = ($m->line_number, $m->column_number);
                        last;
                    }
                }
            }
            push @_CALLBACK_PARAMS, +{
                name        => '$_',
                type        => $elem_type,
                line        => $topic_line,
                col         => $topic_col,
                scope_start => $block_line,
                scope_end   => $block_end,
            };
        }
    }

    if ($name eq 'map') {
        return undef unless $elem_type;
        # Build env with $_ bound to element type
        my %new_vars = ($env->{variables} // +{})->%*;
        $new_vars{'$_'} = $elem_type;
        my $inner_env = +{ %$env, variables => \%new_vars };
        # Extract element expected type from Array[T]
        my $block_expected = ($expected && $expected->is_param && $expected->base eq 'Array')
            ? ($expected->params)[0] : undef;
        my $ret = _infer_block_return($block, $inner_env, $block_expected);
        # Widen literals to base atoms
        $ret = Typist::Type::Atom->new($ret->base_type)
            if $ret && $ret->is_literal;
        # List type: map returns a list, not a reference
        return Typist::Type::Param->new('Array', $ret // Typist::Type::Atom->new('Any'));
    }

    if ($name eq 'grep' || $name eq 'sort') {
        return $elem_type
            ? Typist::Type::Param->new('Array', $elem_type)
            : undef;
    }

    undef;
}

# Walk siblings after the block to find the source list, then infer its element type.
# Patterns: @$var, @array, $arrayref, func(...)
sub _infer_source_element_type_after ($block, $env) {
    my $sib = $block->snext_sibling;
    return undef unless $sib;

    # Skip leading comma if present
    if ($sib->isa('PPI::Token::Operator') && $sib->content eq ',') {
        $sib = $sib->snext_sibling;
        return undef unless $sib;
    }

    # @$ref — Cast('@') + Symbol
    if ($sib->isa('PPI::Token::Cast') && $sib->content eq '@') {
        my $sym = $sib->snext_sibling;
        if ($sym && $sym->isa('PPI::Token::Symbol')) {
            my $var_type = _lookup_var($sym->content, $env);
            return _unwrap_arrayref($var_type) if $var_type;
        }
        return undef;
    }

    # @array — Symbol with @ sigil
    if ($sib->isa('PPI::Token::Symbol') && $sib->raw_type eq '@') {
        my $scalar = $sib->content;
        $scalar =~ s/\A\@/\$/;
        my $var_type = _lookup_var($scalar, $env)
                    // _lookup_var($sib->content, $env);  # fallback: @name key
        return _unwrap_arrayref($var_type) if $var_type;
        return undef;
    }

    # $ref — scalar Symbol → ArrayRef unwrap
    if ($sib->isa('PPI::Token::Symbol') && $sib->raw_type eq '$') {
        my $var_type = _lookup_var($sib->content, $env);
        return _unwrap_arrayref($var_type) if $var_type;
        return undef;
    }

    # func(...) — Word + List
    if ($sib->isa('PPI::Token::Word')) {
        my $after = $sib->snext_sibling;
        if ($after && $after->isa('PPI::Structure::List')) {
            my $ret = _infer_call($sib->content, $env, $after);
            return _unwrap_arrayref($ret) if $ret;
        }
        return undef;
    }

    undef;
}


# ── Anonymous Sub Inference ────────────────────────

# Infer the type of an anonymous sub expression: sub [($sig)] { body }
# Uses bidirectional inference: if $expected is a Func type, propagates
# parameter types and checks arity. Infers return type from block body.
sub _infer_anon_sub ($element, $env = undef, $expected = undef) {
    my $param_count = 0;
    my $sig_node;
    my $block;
    my $next = $element->snext_sibling;

    # Signature (PPI parses as Prototype for anonymous subs)
    if ($next && ($next->isa('PPI::Structure::List') || $next->isa('PPI::Token::Prototype'))) {
        $sig_node = $next;
        $param_count = _count_sub_params($next);
        $next = $next->snext_sibling;
    }

    # Block body
    $block = $next if $next && $next->isa('PPI::Structure::Block');

    # Bidirectional: if expected type is Func, propagate param types
    if ($expected && $expected->is_func) {
        my @expected_params = $expected->params;
        my @params;

        my $arity_match = ($param_count == scalar @expected_params)
            || ($expected->variadic && $param_count >= scalar(@expected_params) - 1);

        if ($arity_match) {
            @params = @expected_params;
        } else {
            @params = map { Typist::Type::Atom->new('Any') } 1 .. $param_count;
        }

        # Infer return type from block body with param types injected into env
        my $ret_type = $expected->returns;
        if ($block && $env) {
            my $body_env = ($sig_node && $arity_match)
                ? _enrich_env_with_params($env, $sig_node, \@params, $block)
                : $env;
            my $body_type = _infer_block_return($block, $body_env, $ret_type);
            $ret_type = $body_type if $body_type;
        }

        return Typist::Type::Func->new(
            \@params, $ret_type // Typist::Type::Atom->new('Any'),
        );
    }

    # No expected type — infer generic Func
    my @params = map { Typist::Type::Atom->new('Any') } 1 .. $param_count;
    my $ret_type = Typist::Type::Atom->new('Any');

    if ($block && $env) {
        my $body_type = _infer_block_return($block, $env);
        $ret_type = $body_type if $body_type;
    }

    Typist::Type::Func->new(\@params, $ret_type);
}

# Count parameters in a sub signature.
# PPI parses anonymous sub signatures as PPI::Token::Prototype (e.g., '($x, $y)'),
# while named sub signatures may use PPI::Structure::List.
sub _count_sub_params ($sig) {
    # Prototype token: parse string content for variable sigils
    if ($sig->isa('PPI::Token::Prototype')) {
        my $content = $sig->content;
        my $count = 0;
        $count++ while $content =~ /[\$\@%]\w/g;
        return $count;
    }

    # List structure: walk children for Symbol tokens
    my $expr = $sig->schild(0);
    return 0 unless $expr;

    my $count = 0;
    for my $tok ($expr->schildren) {
        $count++ if $tok->isa('PPI::Token::Symbol') && $tok->content =~ /\A[\$\@%]/;
    }
    $count;
}

# Extract parameter names from a sub signature node.
# Returns ['$x', '$y'] etc.  Mirrors _count_sub_params but returns names.
sub _extract_param_names ($sig) {
    if ($sig->isa('PPI::Token::Prototype')) {
        my $content = $sig->content;
        my @names;
        push @names, $1 while $content =~ /([\$\@%]\w+)/g;
        return \@names;
    }

    my $expr = $sig->schild(0);
    return [] unless $expr;

    my @names;
    for my $tok ($expr->schildren) {
        push @names, $tok->content
            if $tok->isa('PPI::Token::Symbol') && $tok->content =~ /\A[\$\@%]/;
    }
    \@names;
}

# Build a new env with parameter name → type bindings injected into {variables}.
# When $block is provided, records param info in the collector for LSP symbol index.
sub _enrich_env_with_params ($env, $sig_node, $expected_types, $block = undef) {
    return $env unless $env && $sig_node && $expected_types && @$expected_types;

    my $names = _extract_param_names($sig_node);
    return $env unless $names && @$names;

    my %new_vars = ($env->{variables} // +{})->%*;
    for my $i (0 .. $#$names) {
        last if $i > $#$expected_types;
        my $type = $expected_types->[$i];
        $new_vars{$names->[$i]} = $type;

        # Record for LSP hover/inlay hints (skip Any params — no useful info)
        if ($block && !($type->is_atom && $type->name eq 'Any')) {
            my $dedup_key = $names->[$i] . ':' . $sig_node->line_number;
            next if $_CALLBACK_PARAMS_SEEN{$dedup_key}++;
            push @_CALLBACK_PARAMS, +{
                name        => $names->[$i],
                type        => $type,
                line        => $sig_node->line_number,
                col         => _param_col($sig_node, $names->[$i]),
                scope_start => $block->line_number,
                scope_end   => $block->last_token->line_number,
            };
        }
    }
    +{ %$env, variables => \%new_vars };
}

# Find column number of a specific parameter name within a signature node.
sub _param_col ($sig_node, $name) {
    if ($sig_node->isa('PPI::Token::Prototype')) {
        my $content = $sig_node->content;
        my $offset = index($content, $name);
        return $sig_node->column_number + ($offset >= 0 ? $offset : 0);
    }
    my $expr = $sig_node->schild(0);
    return $sig_node->column_number unless $expr;
    for my $tok ($expr->schildren) {
        return $tok->column_number
            if $tok->isa('PPI::Token::Symbol') && $tok->content eq $name;
    }
    $sig_node->column_number;
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

=head2 callback_params

    my $params = Typist::Static::Infer->callback_params;

Return an arrayref of callback parameter bindings collected during the most
recent inference pass.  Each entry records a parameter name and its inferred
type, for consumption by the symbol index.

=cut

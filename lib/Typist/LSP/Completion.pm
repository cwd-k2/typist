package Typist::LSP::Completion;
use v5.40;

our $VERSION = '0.01';

# ── Primitive and Parametric Types ───────────────

my @PRIMITIVES   = qw(Any Void Never Undef Bool Int Double Num Str);
my @PARAMETRICS  = qw(ArrayRef HashRef Array Hash Tuple Ref Maybe CodeRef);
my @TYPE_VARS    = qw(T U V K);

# ── Public API ───────────────────────────────────

# Generate completion items based on context.
#   context:     'type_expr' | 'generic' | 'effect' | 'constraint'
#   typedefs:    arrayref of typedef names from workspace
#   effects:     arrayref of effect names from workspace
#   typeclasses: arrayref of typeclass names from workspace
sub complete ($class, $context, $typedefs, $effects, $typeclasses = undef, $doc_type_vars = undef) {
    $typedefs      //= [];
    $effects       //= [];
    $typeclasses   //= [];
    $doc_type_vars //= [];

    if ($context eq 'generic') {
        my %seen;
        my @items;
        # Document-level type variable names first
        for my $tv (@$doc_type_vars) {
            next if $seen{$tv}++;
            push @items, _item($tv, 'TypeParameter', "$tv type variable (from document)");
        }
        # Standard type variable suggestions
        for my $tv (@TYPE_VARS) {
            next if $seen{$tv}++;
            push @items, _item($tv, 'TypeParameter', "$tv type variable");
        }
        return \@items;
    }

    if ($context eq 'effect') {
        return [map { _item($_, 'Event', "effect $_") } @$effects];
    }

    if ($context eq 'constraint') {
        return [map { _item($_, 'Interface', "typeclass $_") } @$typeclasses];
    }

    if ($context eq 'type_expr') {
        my @items;

        # Primitives
        push @items, map { _item($_, 'Class', "Primitive type $_") } @PRIMITIVES;

        # Parametric types with snippet insertion
        push @items, map { _item_snippet($_, 'Class') } @PARAMETRICS;

        # Quantified type snippet
        push @items, +{
            label            => 'forall',
            kind             => _kind_number('Class'),
            detail           => 'Rank-2 quantified type: forall T. ...',
            insertText       => 'forall ${1:T}. ${2:($1) -> $1}',
            insertTextFormat => 2,  # Snippet
        };

        # Workspace typedefs
        push @items, map { _item($_, 'Class', "typedef $_") } @$typedefs;

        return \@items;
    }

    [];
}

# ── Code Completion API ────────────────────────

# Generate code completion items based on code-level context.
#   context:  { kind => ..., ... } from Document->code_completion_at
#   doc:      Typist::LSP::Document (analyzed)
#   registry: Typist::Registry
my %_CODE_DISPATCH = (
    record_field => '_complete_record_fields',
    method       => '_complete_methods',
    effect_op    => '_complete_effect_ops',
    match_arm    => '_complete_match_arms',
    variable     => '_complete_variables',
    function     => '_complete_functions',
);

sub complete_code ($class, $context, $doc, $registry) {
    my $method = $_CODE_DISPATCH{$context->{kind}} // return [];
    $class->$method($context, $doc, $registry);
}

sub _complete_record_fields ($class, $context, $doc, $registry) {
    my $var_name = $context->{var};
    my $prefix   = $context->{prefix} // '';

    my $type_str = $doc->resolve_var_type($var_name) // return [];

    # Parse the type string into a type object
    require Typist::Parser;
    my $type = eval { Typist::Parser->parse($type_str) };
    return [] if $@ || !$type;

    # If it's an alias, try to resolve it
    if ($type->is_alias && $registry) {
        $type = eval { $registry->lookup_type($type->alias_name) } // $type;
    }

    return [] unless $type->is_record;

    my @items;
    my $req = $type->required_ref;
    my $opt = $type->optional_ref;

    for my $field (sort keys %$req) {
        next if $prefix ne '' && index($field, $prefix) != 0;
        push @items, +{
            label  => $field,
            kind   => 5,  # Field
            detail => $req->{$field}->to_string,
        };
    }
    for my $field (sort keys %$opt) {
        next if $prefix ne '' && index($field, $prefix) != 0;
        push @items, +{
            label  => $field,
            kind   => 5,  # Field
            detail => $opt->{$field}->to_string . ' (optional)',
        };
    }

    \@items;
}

sub _complete_methods ($class, $context, $doc, $registry) {
    my $prefix = $context->{prefix} // '';
    my $var    = $context->{var} // '$self';

    return [] unless $registry;

    # Cross-package: resolve variable type → struct fields/methods
    if ($var ne '$self') {
        return $class->_complete_cross_package_methods($context, $doc, $registry);
    }

    # Same-package ($self->): existing logic
    my $result = $doc->result // return [];
    my $pkg    = $result->{extracted}{package} // 'main';

    my @items;

    my %methods = $registry->all_methods;
    my $pkg_prefix = "${pkg}::";
    for my $fqn (sort keys %methods) {
        next unless index($fqn, $pkg_prefix) == 0;
        my $name = substr($fqn, length($pkg_prefix));
        next if $prefix ne '' && index($name, $prefix) != 0;
        my $sig = $methods{$fqn};
        my $detail = _sig_detail($sig);
        push @items, +{
            label  => $name,
            kind   => 2,  # Method
            detail => $detail,
        };
    }

    my %functions = $registry->all_functions;
    for my $fqn (sort keys %functions) {
        next unless index($fqn, $pkg_prefix) == 0;
        my $name = substr($fqn, length($pkg_prefix));
        next if $prefix ne '' && index($name, $prefix) != 0;
        next if exists $methods{"${pkg}::${name}"};
        my $sig = $functions{$fqn};
        my $extracted_fn = ($doc->result // +{})->{extracted}{functions}{$name};
        next unless $extracted_fn && $extracted_fn->{is_method};
        my $detail = _sig_detail($sig);
        push @items, +{
            label  => $name,
            kind   => 2,  # Method
            detail => $detail,
        };
    }

    \@items;
}

sub _complete_cross_package_methods ($class, $context, $doc, $registry) {
    my $var    = $context->{var};
    my $prefix = $context->{prefix} // '';

    my $type_str = $doc->resolve_var_type($var) // return [];

    require Typist::Parser;
    my $type = eval { Typist::Parser->parse($type_str) };
    return [] if $@ || !$type;

    my $resolved = $doc->resolve_type_deep($type, $registry);

    # EffectScope: complete effect operation names
    if ($resolved && $resolved->to_string =~ /\AEffectScope\[(\w+)\]\z/) {
        my $effect_name = $1;
        my $eff = $registry->lookup_effect($effect_name) // return [];
        my @items;
        for my $op ($eff->op_names) {
            next if $prefix ne '' && index($op, $prefix) != 0;
            my $op_type = $eff->get_op_type($op);
            my $detail = $op_type ? $op_type->to_string : ($eff->get_op($op) // '');
            push @items, +{
                label  => $op,
                kind   => 2,  # Method
                detail => "EffectScope[$effect_name]::$op $detail",
            };
        }
        return \@items;
    }

    # Must resolve to a struct for field/method completion
    my $struct = ($resolved && $resolved->is_struct) ? $resolved
               : $registry->lookup_struct($type_str =~ s/\[.*//r) // return [];

    my @items;
    my %req = $struct->required_fields;
    my %opt = $struct->optional_fields;

    for my $f (sort keys %req) {
        next if $prefix ne '' && index($f, $prefix) != 0;
        push @items, +{
            label  => $f,
            kind   => 5,  # Field
            detail => $req{$f}->to_string,
        };
    }
    for my $f (sort keys %opt) {
        next if $prefix ne '' && index($f, $prefix) != 0;
        push @items, +{
            label  => $f,
            kind   => 5,  # Field
            detail => $opt{$f}->to_string . '?',
        };
    }
    \@items;
}

sub _complete_match_arms ($class, $context, $doc, $registry) {
    my $var  = $context->{var};
    my %used = map { $_ => 1 } ($context->{used} // [])->@*;

    my $type_str = $doc->resolve_var_type($var) // return [];
    require Typist::Parser;
    my $type = eval { Typist::Parser->parse($type_str) };
    return [] if $@ || !$type;

    # Alias → datatype resolution
    my $dt_name = $type->is_alias ? $type->alias_name : $type->to_string;
    my $dt = $registry ? $registry->lookup_datatype($dt_name) : undef;
    return [] unless $dt;

    my @items;
    for my $tag (sort keys($dt->variants->%*)) {
        next if $used{$tag};
        my @fields = ($dt->variants->{$tag} // [])->@*;
        my $detail = @fields ? "$tag(" . join(', ', map { $_->to_string } @fields) . ")" : $tag;
        push @items, +{
            label            => $tag,
            kind             => 20,  # EnumMember
            detail           => $detail,
            insertText       => "$tag => sub (\${1}) {\n\t\${0}\n}",
            insertTextFormat => 2,
        };
    }
    unless ($used{'_'}) {
        push @items, +{
            label            => '_',
            kind             => 20,  # EnumMember
            detail           => 'fallback',
            insertText       => '_ => sub { ${0} }',
            insertTextFormat => 2,
        };
    }
    \@items;
}

sub _complete_effect_ops ($class, $context, $, $registry) {
    my $effect_name = $context->{effect};
    my $prefix      = $context->{prefix} // '';

    return [] unless $registry;

    my $eff = $registry->lookup_effect($effect_name) // return [];

    my @items;
    for my $op ($eff->op_names) {
        next if $prefix ne '' && index($op, $prefix) != 0;
        my $type_str = $eff->get_op($op) // '';
        push @items, +{
            label  => $op,
            kind   => 2,  # Method
            detail => "$effect_name\::$op $type_str",
        };
    }

    \@items;
}

sub _complete_variables ($class, $context, $doc, $) {
    my $prefix = $context->{prefix} // '';
    my $line   = $context->{line};

    my $result  = $doc->result // return [];
    my $symbols = $result->{symbols} // return [];

    my $ppi_line = defined $line ? $line + 1 : undef;

    my %seen;
    my @items;

    for my $sym (@$symbols) {
        my $kind = $sym->{kind} // '';
        next unless $kind eq 'variable' || $kind eq 'parameter';
        my $name = $sym->{name} // next;
        next unless $name =~ /^\$/;

        my $bare = substr($name, 1);
        next if $prefix ne '' && index($bare, $prefix) != 0;

        if ($ppi_line && $sym->{scope_start} && $sym->{scope_end}) {
            next unless $ppi_line >= $sym->{scope_start}
                     && $ppi_line <= $sym->{scope_end};
        }

        next if $seen{$name}++;

        push @items, +{
            label  => $name,
            kind   => 6,  # Variable
            detail => $sym->{type} // '',
        };
    }

    \@items;
}

sub _complete_functions ($class, $context, $doc, $registry) {
    my $prefix = $context->{prefix} // '';
    return [] unless $registry;

    my $result = $doc->result // return [];
    my $pkg    = $result->{extracted}{package} // 'main';

    my %seen;
    my @items;
    my %functions = $registry->all_functions;

    # Same-package functions
    my $pkg_prefix = "${pkg}::";
    for my $fqn (sort keys %functions) {
        next unless index($fqn, $pkg_prefix) == 0;
        my $name = substr($fqn, length($pkg_prefix));
        next if $prefix ne '' && index($name, $prefix) != 0;
        next if $seen{$name}++;
        push @items, +{
            label  => $name,
            kind   => 3,  # Function
            detail => _sig_detail($functions{$fqn}),
        };
    }

    # Functions from use-imported packages
    for my $used_pkg ($registry->package_uses($pkg)) {
        my $used_prefix = "${used_pkg}::";
        for my $fqn (sort keys %functions) {
            next unless index($fqn, $used_prefix) == 0;
            my $name = substr($fqn, length($used_prefix));
            next if $prefix ne '' && index($name, $prefix) != 0;
            next if $seen{$name}++;
            push @items, +{
                label  => $name,
                kind   => 3,  # Function
                detail => _sig_detail($functions{$fqn}),
            };
        }
    }

    \@items;
}

# Build a human-readable detail string from a function signature hash.
sub _sig_detail ($sig) {
    my @params;
    if ($sig->{params}) {
        @params = map { ref $_ ? $_->to_string : $_ } @{$sig->{params}};
    } elsif ($sig->{params_expr}) {
        @params = @{$sig->{params_expr}};
    }
    my $detail = '(' . join(', ', @params) . ')';
    if ($sig->{returns}) {
        $detail .= ' -> ' . (ref $sig->{returns} ? $sig->{returns}->to_string : $sig->{returns});
    } elsif ($sig->{returns_expr}) {
        $detail .= " -> $sig->{returns_expr}";
    }
    $detail;
}

# ── Item Builders ────────────────────────────────

sub _item ($label, $kind, $detail) {
    +{
        label  => $label,
        kind   => _kind_number($kind),
        detail => $detail,
    };
}

sub _item_snippet ($name, $kind) {
    +{
        label            => $name,
        kind             => _kind_number($kind),
        detail           => "Parametric type $name\[...]",
        insertText       => "${name}[\${1}]",
        insertTextFormat => 2,  # Snippet
    };
}

# LSP CompletionItemKind numbers
sub _kind_number ($kind) {
    my %kinds = (
        Class         => 7,
        Interface     => 8,
        Event         => 23,
        TypeParameter => 25,
    );
    $kinds{$kind} // 1;
}

1;

__END__

=head1 NAME

Typist::LSP::Completion - Completion providers for type annotations and code

=head1 SYNOPSIS

    use Typist::LSP::Completion;

    # Type annotation completion
    my $items = Typist::LSP::Completion->complete(
        'type_expr', \@typedefs, \@effects, \@typeclasses,
    );

    # Code-level completion
    my $items = Typist::LSP::Completion->complete_code($context, $doc, $registry);

=head1 DESCRIPTION

Typist::LSP::Completion generates completion items for both type
annotation contexts (inside C<:sig(...)>) and code-level contexts
(struct field access, method calls, effect operations).

=head1 CLASS METHODS

=head2 complete

    my $items = Typist::LSP::Completion->complete(
        $context, \@typedefs, \@effects, \@typeclasses,
    );

Generate completion items for type annotation contexts. The C<$context>
parameter is one of:

=over 4

=item C<type_expr> - Primitive types, parametric types (with snippet insertion), and workspace typedefs

=item C<generic> - Type variable suggestions (C<T>, C<U>, C<V>, C<K>)

=item C<effect> - Effect names from the workspace

=item C<constraint> - Typeclass names for bounded quantification

=back

=head2 complete_code

    my $items = Typist::LSP::Completion->complete_code($context, $doc, $registry);

Generate code-level completion items. The C<$context> hashref (from
C<Document-E<gt>code_completion_at>) determines the completion kind:

=over 4

=item C<record_field> - Struct field names based on the variable's type

=item C<method> - Method names for C<$self-E<gt>> calls within the same package

=item C<effect_op> - Effect operation names for C<Effect::> qualified calls

=item C<variable> - Variable names (C<$> prefix) with types from analysis

=item C<function> - Function names (bare word) from same and imported packages

=back

=head1 SEE ALSO

L<Typist::LSP::Server>, L<Typist::LSP::Document>

=cut

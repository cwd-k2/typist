package Typist::Static::Extractor;
use v5.40;

use PPI;

# ── Public API ───────────────────────────────────

# Extract type annotations from Perl source text.
# Returns a structured hash of aliases, variables, functions, and package name.
sub extract ($class, $source) {
    my $doc = PPI::Document->new(\$source)
        or die "Typist::Static::Extractor: failed to parse source";

    my $result = +{
        aliases     => +{},
        variables   => [],
        functions   => +{},
        newtypes    => +{},
        datatypes   => +{},
        effects     => +{},
        typeclasses => +{},
        declares    => +{},
        package     => 'main',
        ppi_doc     => $doc,
    };

    # Detect package declaration
    if (my $pkg = $doc->find_first('PPI::Statement::Package')) {
        $result->{package} = $pkg->namespace;
    }

    $class->_extract_typedefs($doc, $result);
    $class->_extract_newtypes($doc, $result);
    $class->_extract_datatypes($doc, $result);
    $class->_extract_effects($doc, $result);
    $class->_extract_typeclasses($doc, $result);
    $class->_extract_declares($doc, $result);
    $class->_extract_variables($doc, $result);
    $class->_extract_functions($doc, $result);

    $result->{ignore_lines} = $class->_collect_ignore_lines($doc);

    $result;
}

# ── typedef Extraction ──────────────────────────

sub _extract_typedefs ($class, $doc, $result) {
    my $statements = $doc->find('PPI::Statement') || [];

    for my $stmt (@$statements) {
        my @children = $stmt->schildren;
        next unless @children >= 4;

        # typedef Name => 'Expr'
        next unless $children[0]->isa('PPI::Token::Word')
                 && $children[0]->content eq 'typedef';

        my $name = $children[1]->content;
        # Skip => operator
        next unless $children[2]->isa('PPI::Token::Operator')
                 && $children[2]->content eq '=>';

        my $expr = $class->_collect_rhs_expr(@children[3 .. $#children]);
        next unless defined $expr;

        $result->{aliases}{$name} = +{
            expr => $expr,
            line => $stmt->line_number,
            col  => $stmt->column_number,
        };
    }
}

# ── Newtype Extraction ─────────────────────────

sub _extract_newtypes ($class, $doc, $result) {
    my $statements = $doc->find('PPI::Statement') || [];

    for my $stmt (@$statements) {
        my @children = $stmt->schildren;
        next unless @children >= 4;

        # newtype Name => 'Expr'
        next unless $children[0]->isa('PPI::Token::Word')
                 && $children[0]->content eq 'newtype';

        my $name = $children[1]->content;
        next unless $children[2]->isa('PPI::Token::Operator')
                 && $children[2]->content eq '=>';

        my $expr = $class->_collect_rhs_expr(@children[3 .. $#children]);
        next unless defined $expr;

        $result->{newtypes}{$name} = +{
            inner_expr => $expr,
            line       => $stmt->line_number,
            col        => $stmt->column_number,
        };
    }
}

# ── Datatype Extraction ────────────────────────

sub _extract_datatypes ($class, $doc, $result) {
    my $statements = $doc->find('PPI::Statement') || [];

    for my $stmt (@$statements) {
        my @children = $stmt->schildren;
        next unless @children >= 4;

        # datatype Name => Tag1 => '(Type, ...)', Tag2 => '(Type)', ...
        next unless $children[0]->isa('PPI::Token::Word')
                 && $children[0]->content eq 'datatype';

        # Name may be a bare word or quoted string (for parameterized: 'Option[T]')
        my $name_tok = $children[1];
        my $name_raw = $name_tok->isa('PPI::Token::Quote')
            ? $name_tok->string
            : $name_tok->content;
        next unless $children[2]->isa('PPI::Token::Operator')
                 && $children[2]->content eq '=>';

        # Parse name and type parameters
        my ($base_name, @type_params);
        if ($name_raw =~ /\A(\w+)\[(.+)\]\z/) {
            $base_name = $1;
            @type_params = map { s/\s//gr } split /,/, $2;
        } else {
            $base_name = $name_raw;
        }

        # Parse variant pairs from remaining children
        my @rest = @children[3 .. $#children];
        my %variants;
        my $i = 0;
        while ($i < @rest) {
            last if $rest[$i]->isa('PPI::Token::Structure')
                 && $rest[$i]->content eq ';';

            # Skip commas
            if ($rest[$i]->isa('PPI::Token::Operator')
                && $rest[$i]->content eq ',')
            {
                $i++;
                next;
            }

            # Expect a tag name (Word)
            last unless $rest[$i]->isa('PPI::Token::Word');
            my $tag = $rest[$i]->content;
            $i++;

            # Expect =>
            last unless $i < @rest
                     && $rest[$i]->isa('PPI::Token::Operator')
                     && $rest[$i]->content eq '=>';
            $i++;

            # Expect a spec (quoted string)
            last unless $i < @rest;
            my $spec_tok = $rest[$i];
            my $spec = $spec_tok->isa('PPI::Token::Quote')
                ? $spec_tok->string
                : $spec_tok->content;
            $variants{$tag} = $spec;
            $i++;
        }

        $result->{datatypes}{$base_name} = +{
            variants    => \%variants,
            type_params => \@type_params,
            line        => $stmt->line_number,
            col         => $stmt->column_number,
        };
    }
}

# ── Effect Extraction ──────────────────────────

sub _extract_effects ($class, $doc, $result) {
    my $statements = $doc->find('PPI::Statement') || [];

    for my $stmt (@$statements) {
        my @children = $stmt->schildren;
        next unless @children >= 3;

        # effect Name => { ... } or effect Name => [ ... ]
        next unless $children[0]->isa('PPI::Token::Word')
                 && $children[0]->content eq 'effect';

        my $name = $children[1]->content;

        $result->{effects}{$name} = +{
            line => $stmt->line_number,
            col  => $stmt->column_number,
        };
    }
}

# ── TypeClass Extraction ───────────────────────

sub _extract_typeclasses ($class, $doc, $result) {
    my $statements = $doc->find('PPI::Statement') || [];

    for my $stmt (@$statements) {
        my @children = $stmt->schildren;
        next unless @children >= 3;

        # typeclass Name => VarSpec, +{ method => sig, ... }
        next unless $children[0]->isa('PPI::Token::Word')
                 && $children[0]->content eq 'typeclass';

        my $name_tok = $children[1];
        my $name = $name_tok->isa('PPI::Token::Quote')
            ? $name_tok->string
            : $name_tok->content;

        # Extract var_spec from [3] (after => operator)
        my $var_spec;
        if (@children >= 4
            && $children[2]->isa('PPI::Token::Operator')
            && $children[2]->content eq '=>')
        {
            my $vs_tok = $children[3];
            $var_spec = $vs_tok->isa('PPI::Token::Quote')
                ? $vs_tok->string
                : $vs_tok->content;
        }

        # Extract method names from the hashref constructor (top-level keys only)
        my @method_names;
        for my $child (@children) {
            next unless $child->isa('PPI::Structure::Constructor')
                     || $child->isa('PPI::Structure::Block');
            # Constructor wraps a single Expression; scan its schildren for Word => patterns
            for my $expr ($child->schildren) {
                next unless $expr->isa('PPI::Statement') || $expr->isa('PPI::Statement::Expression');
                my @sc = $expr->schildren;
                for my $i (0 .. $#sc - 1) {
                    if ($sc[$i]->isa('PPI::Token::Word')
                        && $sc[$i + 1]->isa('PPI::Token::Operator')
                        && $sc[$i + 1]->content eq '=>')
                    {
                        push @method_names, $sc[$i]->content;
                    }
                }
            }
            last;
        }

        $result->{typeclasses}{$name} = +{
            var_spec     => $var_spec,
            method_names => \@method_names,
            line         => $stmt->line_number,
            col          => $stmt->column_number,
        };
    }
}

# ── Declare Extraction ─────────────────────────

sub _extract_declares ($class, $doc, $result) {
    my $statements = $doc->find('PPI::Statement') || [];

    for my $stmt (@$statements) {
        my @children = $stmt->schildren;
        next unless @children >= 4;

        # declare NAME => 'type_expr'
        # declare 'Pkg::Name' => 'type_expr'
        next unless $children[0]->isa('PPI::Token::Word')
                 && $children[0]->content eq 'declare';

        # Name: bare Word or quoted string
        my $name_tok = $children[1];
        my $name;
        if ($name_tok->isa('PPI::Token::Quote')) {
            $name = $name_tok->string;
        } elsif ($name_tok->isa('PPI::Token::Word')) {
            $name = $name_tok->content;
        } else {
            next;
        }

        # => operator
        next unless $children[2]->isa('PPI::Token::Operator')
                 && $children[2]->content eq '=>';

        my $type_expr = $class->_collect_rhs_expr(@children[3 .. $#children]);
        next unless defined $type_expr;

        # Determine package and function name
        my ($pkg, $fn_name);
        if ($name =~ /\A(.+)::(\w+)\z/) {
            ($pkg, $fn_name) = ($1, $2);
        } else {
            ($pkg, $fn_name) = ('CORE', $name);
        }

        $result->{declares}{$name} = +{
            name      => $name,
            package   => $pkg,
            func_name => $fn_name,
            type_expr => $type_expr,
            line      => $stmt->line_number,
            col       => $stmt->column_number,
        };
    }
}

# ── Variable Extraction ─────────────────────────

# PPI does not recognize variable attributes as PPI::Token::Attribute.
# Instead, `my $x :Type(Int)` is parsed as:
#   Symbol($x) Operator(:) Word(Type) List( Expression(Word(Int)) )
# We detect this pattern by scanning PPI::Statement::Variable children.
sub _extract_variables ($class, $doc, $result) {
    my $stmts = $doc->find('PPI::Statement::Variable') || [];
    my %typed_vars;

    # First pass: annotated variables (:Type(...))
    for my $stmt (@$stmts) {
        my @children = $stmt->schildren;

        # Find the variable symbol
        my $var_name;
        for my $i (0 .. $#children) {
            my $child = $children[$i];

            if ($child->isa('PPI::Token::Symbol')) {
                $var_name = $child->content;
                next;
            }

            # Look for : operator followed by Word('Type') followed by List
            next unless $child->isa('PPI::Token::Operator')
                     && $child->content eq ':'
                     && $var_name;

            my $next = $children[$i + 1] // next;
            next unless $next->isa('PPI::Token::Word')
                     && $next->content eq 'Type';

            my $list = $children[$i + 2] // next;
            next unless $list->isa('PPI::Structure::List');

            # Extract the type expression from the list content
            my $type_expr = $class->_list_content($list);
            next unless $type_expr;

            # Find the initializer node (RHS of '=')
            my $init_node;
            for my $j ($i + 3 .. $#children) {
                if ($children[$j]->isa('PPI::Token::Operator') && $children[$j]->content eq '=') {
                    $init_node = $children[$j + 1] if $j + 1 <= $#children;
                    last;
                }
            }

            $typed_vars{$var_name} = 1;
            push $result->{variables}->@*, +{
                name      => $var_name,
                type_expr => $type_expr,
                line      => $next->line_number,
                col       => $next->column_number,
                init_node => $init_node,
            };
        }
    }

    # Second pass: unannotated variables with initializer (for flow typing)
    for my $stmt (@$stmts) {
        my @children = $stmt->schildren;
        my ($var_name, $var_sym, $init_node);

        for my $i (0 .. $#children) {
            if ($children[$i]->isa('PPI::Token::Symbol') && !$var_name) {
                $var_name = $children[$i]->content;
                $var_sym  = $children[$i];
            }
            if ($children[$i]->isa('PPI::Token::Operator') && $children[$i]->content eq '=') {
                $init_node = $children[$i + 1] if $i + 1 <= $#children;
                last;
            }
        }

        next unless $var_name && $init_node;
        next if $typed_vars{$var_name};

        push $result->{variables}->@*, +{
            name      => $var_name,
            type_expr => undef,
            line      => $var_sym->line_number,
            col       => $var_sym->column_number,
            init_node => $init_node,
        };
    }
}

# ── Function Extraction ─────────────────────────

sub _extract_functions ($class, $doc, $result) {
    my $subs = $doc->find('PPI::Statement::Sub') || [];

    for my $sub_stmt (@$subs) {
        my $name = $sub_stmt->name // next;

        # Detect method: first parameter is $self or $class
        my $param_names = $class->_extract_sig_params($sub_stmt);
        my ($is_method, $method_kind) = (0, undef);
        if (@$param_names && $param_names->[0] eq '$self') {
            ($is_method, $method_kind) = (1, 'instance');
        }
        elsif (@$param_names && $param_names->[0] eq '$class') {
            ($is_method, $method_kind) = (1, 'class');
        }

        my $attrs = $sub_stmt->find('PPI::Token::Attribute') || [];

        if (@$attrs) {
            # Look for :Type(...) annotation
            my $type_ann;
            for my $attr (@$attrs) {
                my $content = $attr->content;
                if ($content =~ /\AType\((.+)\)\z/s) {
                    $type_ann = $1;
                    last;
                }
            }

            if ($type_ann) {
                my $ann = eval {
                    require Typist::Parser;
                    Typist::Parser->parse_annotation($type_ann);
                };
                next if $@;

                my $type = $ann->{type};
                my (@params_expr, $returns_expr, $eff_expr);

                my $variadic = 0;
                if ($type->is_func) {
                    @params_expr = map { $_->to_string } $type->params;
                    $returns_expr = $type->returns->to_string;
                    $eff_expr = $type->effects
                        ? $type->effects->to_string : undef;
                    $variadic = $type->variadic;
                } else {
                    $returns_expr = $type->to_string;
                }

                $result->{functions}{$name} = +{
                    params_expr  => \@params_expr,
                    returns_expr => $returns_expr,
                    generics     => $ann->{generics_raw},
                    eff_expr     => $eff_expr,
                    variadic     => $variadic,
                    param_names  => $param_names,
                    is_method    => $is_method,
                    method_kind  => $method_kind,
                    line         => $sub_stmt->line_number,
                    end_line     => $class->_end_line($sub_stmt),
                    col          => $sub_stmt->column_number,
                    block        => $sub_stmt->block,
                };
            }
            # No :Type annotation — skip
        }
        else {
            # Unannotated function: count signature params for Any... -> Any !Eff(*)
            # For methods, exclude $self/$class from the parameter count
            my $arity = scalar @$param_names;
            $arity -= 1 if $is_method && $arity > 0;

            $result->{functions}{$name} = +{
                params_expr  => [('Any') x $arity],
                returns_expr => 'Any',
                generics     => [],
                eff_expr     => undef,
                unannotated  => 1,
                param_names  => $param_names,
                is_method    => $is_method,
                method_kind  => $method_kind,
                line         => $sub_stmt->line_number,
                end_line     => $class->_end_line($sub_stmt),
                col          => $sub_stmt->column_number,
                block        => $sub_stmt->block,
            };
        }
    }
}

# ── Ignore Lines ─────────────────────────────────

# Collect lines suppressed by @typist-ignore comments.
# A comment containing @typist-ignore on line N suppresses diagnostics on line N+1.
sub _collect_ignore_lines ($class, $doc) {
    my $comments = $doc->find('PPI::Token::Comment') || [];
    my %ignored;

    for my $comment (@$comments) {
        next unless $comment->content =~ /\@typist-ignore/;
        $ignored{ $comment->line_number + 1 } = 1;
    }

    \%ignored;
}

# ── Helpers ──────────────────────────────────────

# Collect RHS expression tokens: everything before ';', joining content.
# Single Quote token → ->string (strip quotes). Otherwise join all token contents.
sub _collect_rhs_expr ($class, @children) {
    my @tokens;
    for my $child (@children) {
        last if $child->isa('PPI::Token::Structure') && $child->content eq ';';
        push @tokens, $child;
    }
    return undef unless @tokens;

    # Single Quote token → strip quotes
    if (@tokens == 1 && $tokens[0]->isa('PPI::Token::Quote')) {
        return $tokens[0]->string;
    }

    # Join all token contents, normalizing whitespace
    my $raw = join '', map { $_->content } @tokens;
    $raw =~ s/\A\s+//;
    $raw =~ s/\s+\z//;
    length($raw) ? $raw : undef;
}

# Extract parameter names from a subroutine signature.
# Returns an arrayref of symbol names (e.g., ['$a', '$b']).
# Only considers direct-child Lists of the sub statement (before the block),
# not Lists nested inside the function body.
sub _extract_sig_params ($class, $sub_stmt) {
    my $sig_list;
    for my $child ($sub_stmt->schildren) {
        last if $child->isa('PPI::Structure::Block');
        $sig_list = $child if $child->isa('PPI::Structure::List');
    }
    return [] unless $sig_list;

    my $inner = $sig_list->find('PPI::Token::Symbol') || [];
    [map { $_->content } @$inner];
}

# Count the number of parameters in a subroutine signature.
sub _count_sig_params ($class, $sub_stmt) {
    scalar $class->_extract_sig_params($sub_stmt)->@*;
}

# Extract the end line of a subroutine block (last token's line number).
sub _end_line ($class, $sub_stmt) {
    my $block = $sub_stmt->block // return undef;
    my $last = $block->last_token // return undef;
    $last->line_number;
}

# Extract the textual content of a PPI::Structure::List, stripping parens.
sub _list_content ($class, $list) {
    my $raw = $list->content;
    $raw =~ s/\A\(\s*//;
    $raw =~ s/\s*\)\z//;
    length($raw) ? $raw : undef;
}

1;

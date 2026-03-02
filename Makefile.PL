use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'Typist',
    VERSION_FROM     => 'lib/Typist.pm',
    ABSTRACT         => 'A static-first type system for Perl 5',
    AUTHOR           => 'cwd-k2',
    LICENSE          => 'mit',
    MIN_PERL_VERSION => 'v5.40',
    EXE_FILES        => ['bin/typist-check', 'bin/typist-lsp'],
    PREREQ_PM        => {
        'PPI' => 0,
    },
    TEST_REQUIRES => {},
    test          => { TESTS => 't/*.t t/static/*.t t/lsp/*.t t/critic/*.t' },
    META_MERGE => {
        'meta-spec' => { version => 2 },
        resources   => {
            repository => {
                type => 'git',
                url  => 'https://github.com/cwd-k2/typist.git',
                web  => 'https://github.com/cwd-k2/typist',
            },
        },
        no_index => {
            directory => [qw(example script docs)],
        },
    },
);

package Typist::LSP;
use v5.40;

our $VERSION = '0.01';

use Typist::LSP::Server;

sub run ($class) {
    my $server = Typist::LSP::Server->new;
    $server->run;

    # LSP spec: exit 0 if shutdown was received, 1 otherwise
    exit($server->did_shutdown ? 0 : 1);
}

1;

__END__

=head1 NAME

Typist::LSP - Entry point for the Typist language server

=head1 DESCRIPTION

Top-level module that bootstraps and runs the Typist LSP server.
Creates a L<Typist::LSP::Server> instance, enters the main loop, and
exits with the appropriate status code per the LSP specification.

=head2 run

    Typist::LSP->run;

Starts the LSP server, blocks on the message loop until shutdown, then
calls C<exit(0)> if a proper shutdown was received or C<exit(1)> otherwise.

=cut

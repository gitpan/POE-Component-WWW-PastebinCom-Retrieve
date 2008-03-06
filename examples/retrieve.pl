#!/usr/bin/env perl

use strict;
use warnings;

die "Usage: perl retrieve.pl <paste_URI_or_ID>\n"
    unless @ARGV;

my $Paste = shift;

use lib '../lib';
use POE qw(Component::WWW::PastebinCom::Retrieve);

my $poco = POE::Component::WWW::PastebinCom::Retrieve->spawn;

POE::Session->create(
    package_states => [ main => [qw(_start retrieved )] ],
);

$poe_kernel->run;

sub _start {
    $poco->retrieve( {
            id    => $Paste,
            event => 'retrieved',
        }
    );
}

sub retrieved {
    my $in = $_[ARG0];
    if ( $in->{error} ) {
        print "Got an error: $in->{error}\n";
    }
    else {
        print "Paste $in->{id} is:\n$in->{content}\n";
    }
    $poco->shutdown;
}


package POE::Component::WWW::PastebinCom::Retrieve;

use warnings;
use strict;

our $VERSION = '0.002';


use Carp;
use WWW::PastebinCom::Retrieve;
use POE qw( Filter::Reference  Filter::Line  Wheel::Run );

sub spawn {
    my $package = shift;
    croak "$package requires an even number of arguments"
        if @_ & 1;

    my %params = @_;
    
    $params{ lc $_ } = delete $params{ $_ } for keys %params;

    delete $params{options}
        unless ref $params{options} eq 'HASH';
    
    $params{obj_args} = {
        timeout => delete( $params{timeout} ),
        ua      => delete( $params{ua}      ),
    };

    my $self = bless \%params, $package;

    $self->{session_id} = POE::Session->create(
        object_states => [
            $self => {
                retrieve => '_retrieve',
                shutdown => '_shutdown',
            },
            $self => [
                qw(
                    _child_error
                    _child_closed
                    _child_stdout
                    _child_stderr
                    _sig_child
                    _start
                )
            ]
        ],
        ( defined $params{options} ? ( options => $params{options} ) : () ),
    )->ID();

    return $self;
}


sub _start {
    my ( $kernel, $self ) = @_[ KERNEL, OBJECT ];
    $self->{session_id} = $_[SESSION]->ID();

    if ( $self->{alias} ) {
        $kernel->alias_set( $self->{alias} );
    }
    else {
        $kernel->refcount_increment( $self->{session_id} => __PACKAGE__ );
    }

    $self->{wheel} = POE::Wheel::Run->new(
        Program    => sub{ _wheel( $self->{obj_args} ); },
        ErrorEvent => '_child_error',
        CloseEvent => '_child_close',
        StdoutEvent => '_child_stdout',
        StderrEvent => '_child_stderr',
        StdioFilter => POE::Filter::Reference->new,
        StderrFilter => POE::Filter::Line->new,
        ( $^O eq 'MSWin32' ? ( CloseOnCall => 0 ) : ( CloseOnCall => 1 ) )
    );

    $kernel->yield('shutdown')
        unless $self->{wheel};

    $kernel->sig_child( $self->{wheel}->PID(), '_sig_child' );

    undef;
}

sub _sig_child {
    $poe_kernel->sig_handled;
}

sub session_id {
    return $_[0]->{session_id};
}

sub retrieve {
    my $self = shift;
    $poe_kernel->post( $self->{session_id} => 'retrieve' => @_ );
}

sub _retrieve {
    my ( $kernel, $self ) = @_[ KERNEL, OBJECT ];
    my $sender = $_[SENDER]->ID;
    
    return
        if $self->{shutdown};
        
    my $args;
    if ( ref $_[ARG0] eq 'HASH' ) {
        $args = { %{ $_[ARG0] } };
    }
    else {
        carp "First parameter must be a hashref, trying to adjust...";
        $args = { @_[ARG0 .. $#_] };
    }
    
    $args->{ lc $_ } = delete $args->{ $_ }
        for grep { !/^_/ } keys %$args;

    unless ( $args->{event} ) {
        carp "Missing 'event' parameter to retrieve";
        return;
    }
    unless ( $args->{id} ) {
        carp "Missing 'id' parameter to retrieve";
        return;
    }

    if ( $args->{session} ) {
        if ( my $ref = $kernel->alias_resolve( $args->{session} ) ) {
            $args->{sender} = $ref->ID;
        }
        else {
            carp "Could not resolve 'session' parameter to a valid"
                    . " POE session";
            return;
        }
    }
    else {
        $args->{sender} = $sender;
    }
    
    $kernel->refcount_increment( $args->{sender} => __PACKAGE__ );
    $self->{wheel}->put( $args );
    
    undef;
}

sub shutdown {
    my $self = shift;
    $poe_kernel->call( $self->{session_id} => 'shutdown' => @_ );
}

sub _shutdown {
    my ( $kernel, $self ) = @_[ KERNEL, OBJECT ];
    $kernel->alarm_remove_all;
    $kernel->alias_remove( $_ ) for $kernel->alias_list;
    $kernel->refcount_decrement( $self->{session_id} => __PACKAGE__ )
        unless $self->{alias};

    $self->{shutdown} = 1;
    
    $self->{wheel}->shutdown_stdin
        if $self->{wheel};
}

sub _child_closed {
    my ( $kernel, $self ) = @_[ KERNEL, OBJECT ];
    
    carp "_child_closed called (@_[ARG0..$#_])\n"
        if $self->{debug};

    delete $self->{wheel};
    $kernel->yield('shutdown')
        unless $self->{shutdown};

    undef;
}

sub _child_error {
    my ( $kernel, $self ) = @_[ KERNEL, OBJECT ];
    carp "_child_error called (@_[ARG0..$#_])\n"
        if $self->{debug};

    delete $self->{wheel};
    $kernel->yield('shutdown')
        unless $self->{shutdown};

    undef;
}

sub _child_stderr {
    my ( $kernel, $self ) = @_[ KERNEL, OBJECT ];
    carp "_child_stderr: $_[ARG0]\n"
        if $self->{debug};

    undef;
}

sub _child_stdout {
    my ( $kernel, $self, $input ) = @_[ KERNEL, OBJECT, ARG0 ];
    
    my $session = delete $input->{sender};
    my $event   = delete $input->{event};

    $kernel->post( $session, $event, $input );
    $kernel->refcount_decrement( $session => __PACKAGE__ );
    
    undef;
}

sub _wheel {
    my $obj_args = shift;

    if ( $^O eq 'MSWin32' ) {
        binmode STDIN;
        binmode STDOUT;
    }
    
    my $raw;
    my $size = 4096;
    my $filter = POE::Filter::Reference->new;

    my $paster = WWW::PastebinCom::Retrieve->new( %$obj_args );

    while ( sysread STDIN, $raw, $size ) {
        my $requests = $filter->get( [ $raw ] );
        foreach my $req_ref ( @$requests ) {

            _process_request( $paster, $req_ref ); # changes $req_ref

            my $response = $filter->put( [ $req_ref ] );
            print STDOUT @$response;
        }
    }
}

sub _process_request {
    my ( $paster, $req_ref ) = @_;
    $req_ref->{content} = $paster->retrieve( $req_ref->{id} );

    unless ( defined $req_ref->{content} ) {
        delete $req_ref->{content};
        $req_ref->{error} = $paster->error;
    }

    undef;
}


1;
__END__


=head1 NAME

POE::Component::WWW::PastebinCom::Retrieve - non-blocking wrapper around WWW::PastebinCom::Retrieve

=head1 SYNOPSIS

    use strict;
    use warnings;

    use POE qw(Component::WWW::PastebinCom::Retrieve);

    my $poco = POE::Component::WWW::PastebinCom::Retrieve->spawn;

    POE::Session->create(
        package_states => [ main => [qw(_start retrieved )] ],
    );

    $poe_kernel->run;

    sub _start {
        $poco->retrieve( {
                id    => 'http://pastebin.com/m73779e58',
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

Using event based interface is also possible of course.

=head2 DESCRIPTION

The module is a non-blocking wrapper around L<WWW::PastebinCom::Retrieve>
which provides interface to retrieve pastes from L<http://pastebin.com>

=head1 CONSTRUCTOR

=head2 spawn

    my $poco = POE::Component::WWW::PastebinCom::Retrieve->spawn;

    POE::Component::WWW::PastebinCom::Retrieve->spawn(
        alias => 'paster',
        timeout => 10,
        # or:  ua => LWP::UserAgent->new( timeout => 10, agent => 'blah),
        options => {
            debug => 1,
            trace => 1,
            # POE::Session arguments for the component
        },
        debug => 1, # output some debug info
    );

The C<spawn> method returns a
POE::Component::WWW::PastebinCom::Retrieve object. It takes a few arguments,
I<all of which are optional>. The possible arguments are as follows:

=head3 alias

    POE::Component::WWW::PastebinCom::Retrieve->spawn(
        alias => 'paster'
    );

B<Optional>. Specifies a POE Kernel alias for the component.

=head3 timeout

    ->spawn( timeout => 10 );

B<Optional>. Specifies the timeout argument of L<LWP::UserAgent>'s
constructor, which is used for pasting. B<Defaults to>: C<30> seconds.

=head3 ua

    ->spawn( ua => LWP::UserAgent->new( agent => 'Foos!' ) );

B<Optional>. If the C<timeout> argument is not enough for your needs of
mutilating the L<LWP::UserAgent> object used for retrieving the pastes, feel
free to specify the C<ua> argument which takes an L<LWP::UserAgent> object
as a value. B<Note:> the C<timeout> argument to the constructor will not do
anything if you specify the C<ua> argument as well. B<Defaults to:> plain
boring default L<LWP::UserAgent> object with C<timeout> argument set to
whatever POE::Component::WWW::PastebinCom::Retrieve's C<timeout> argument is
set to as well as C<agent> argument is set to mimic Firefox.

=head3 options

    my $poco = POE::Component::WWW::PastebinCom::Retrieve->spawn(
        options => {
            trace => 1,
            default => 1,
        },
    );

B<Optioanl>.
A hashref of POE Session options to pass to the component's session.

=head3 debug

    my $poco = POE::Component::WWW::PastebinCom::Retrieve->spawn(
        debug => 1
    );

When set to a true value turns on output of debug messages. B<Defaults to:>
C<0>.

=head1 METHODS

=head2 retrieve

    $poco->retrieve( {
            event => 'event_for_output',
            id    => 'http://pastebin.com/m73779e58',
            # or just 'm73779e58',
            _blah => 'pooh!',
            session => 'other',
        }
    );

Takes a hashref as an argument, does not return a sensible return value.
See C<retrieve> event's description for more information.

=head2 session_id

    my $poco_id = $poco->session_id;

Takes no arguments. Returns component's session ID.

=head2 shutdown

    $poco->shutdown;

Takes no arguments. Shuts down the component.

=head1 ACCEPTED EVENTS

=head2 retrieve

    $poe_kernel->post( paster => retrieve => {
            event => 'event_for_output',
            id    => 'http://pastebin.com/m73779e58',
            # or just 'm73779e58',
            _blah => 'pooh!',
            session => 'other',
        }
    );

=head3 event

    { event => 'results_event', }

B<Mandatory>. Specifies the name of the event to emit when results are
ready. See OUTPUT section for more information.

=head3 id

    { id => 'http://pastebin.com/m73779e58' }

    { id => 'm73779e58' }

B<Mandatory>. As a value takes a full URI to the paste you want to retrieve
or just its ID.

=head3 user defined

    {
        _user    => 'random',
        _another => 'more',
    }

B<Optional>. Any keys starting with C<_> (underscore) will not affect the
component and will be passed back in the result intact.

=head2 shutdown

    $poe_kernel->post( paster => 'shutdown' );

Takes no arguments. Tells the component to shut itself down.

=head1 OUTPUT

    $VAR1 = {
        'id'  => 'http://pastebin.com/m73779e58',
        'content' => 'blah blah',
    }

The event handler set up to handle the event which you've specified in
the C<event> argument to C<retrieve()> method/event will recieve input
in the C<$_[ARG0]> in a form of a hashref. The possible keys/value of
that hashref are as follows:

=head2 content

If the paste was retrieved successfully the C<content> key will contain
the content of the paste as its value.

=head2 error

If there was some problem while retrieving your paste the C<content> key
will not be present and the C<error> key will be present instead and
will contain a human parsable description of the error.

=head2 id

The C<id> key will contain whatever you've specified as an C<id> argument
to C<retrieve()> event/method.

=head3 session

    { session => 'other' }

    { session => $other_session_reference }

    { session => $other_session_ID }

B<Optional>. Takes either an alias, reference or an ID of an alternative
session to send output to.

=head2 user defined

Any arguments beginning with C<_> (underscore) passed into the C<retrieve()>
event/method will be present intact in the result.

=head1 AUTHOR

Zoffix Znet, C<< <zoffix at cpan.org> >>
(L<http://zoffix.com>, L<http://haslayout.net>)

=head1 BUGS

Please report any bugs or feature requests to C<bug-poe-component-www-pastebincom-retrieve at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=POE-Component-WWW-PastebinCom-Retrieve>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc POE::Component::WWW::PastebinCom::Retrieve

You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=POE-Component-WWW-PastebinCom-Retrieve>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/POE-Component-WWW-PastebinCom-Retrieve>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/POE-Component-WWW-PastebinCom-Retrieve>

=item * Search CPAN

L<http://search.cpan.org/dist/POE-Component-WWW-PastebinCom-Retrieve>

=back

=head1 COPYRIGHT & LICENSE

Copyright 2008 Zoffix Znet, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

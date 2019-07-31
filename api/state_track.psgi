use strict;
use warnings;
use JSON;
use Plack::Builder;
use Plack::Request;
use Plack::App::EventSource;
use Couchbase::Bucket;

BEGIN {
    if( not defined($ENV{'STATE_TRACK_CFG'}) )
    {
        die('missing STATE_TRACK_CFG environment variable');
    }

    if( not -r $ENV{'STATE_TRACK_CFG'} )
    {
        die('Cannot access ' . $ENV{'STATE_TRACK_CFG'});
    }

    $CFG::dbhost = '127.0.0.1';
    $CFG::bucket = 'state_track';
    $CFG::dbuser = 'Administrator';
    $CFG::dbpw = 'password';
    $CFG::apiprefix = '/strack/';
    
    do $ENV{'STATE_TRACK_CFG'};
    die($@) if($@);
    die($!) if($!);
};


my $json = JSON->new()->canonical();


sub get_writer
{
    my $responder = shift;
    return $responder->
        (
         [
          200,
          [
           'Content-Type' => 'text/event-stream; charset=UTF-8',
           'Cache-Control' => 'no-store, no-cache, must-revalidate, max-age=0',
          ]
         ]
        );
}


sub send_event
{
    my $writer = shift;
    my $event = shift;

    my @lines;
    while( scalar(@{$event}) > 0 )
    {
        push(@lines, shift(@{$event}) . ': ' . shift(@{$event}));
    }
    
    $writer->write(join("\x0d\x0a", @lines) . "\x0d\x0a\x0d\x0a");
}

sub iterate_and_push
{
    my $cb = shift;
    my $rv = $cb->query_iterator(@_);

    return sub {
        my $responder = shift;
        my $writer = get_writer($responder);

        while( (my $row = $rv->next()) )
        {
            my $event = ['event', 'row'];
            if( defined($row->{'id'}) )
            {
                push(@{$event}, 'id', $row->{'id'});
            }

            push(@{$event}, 'data', $json->encode({%{$row}}));
            send_event($writer, $event);
        }
        
        send_event($writer, ['event', 'end']);
        $writer->close();
    };
}
         

sub push_one_or_nothing
{
    my $val = shift;
    
    return sub {
        my $responder = shift;
        my $writer = get_writer($responder);
        if( defined($val) )
        {
            send_event($writer, ['event', 'row', 'data', $json->encode({%{$val}})]);
        }
        send_event($writer, ['event', 'end']);
        $writer->close();
    }
}


sub error
{
    my $req = shift;
    my $msg = shift;
    my $res = $req->new_response(400);
    $res->content_type('text/plain');
    $res->body($msg . "\x0d\x0a");
    return $res->finalize;
}

    

my $cb = Couchbase::Bucket->new('couchbase://' . $CFG::dbhost . '/' . $CFG::bucket,
                                {'username' => $CFG::dbuser, 'password' => $CFG::dbpw});




my $builder = Plack::Builder->new;

$builder->mount
    ($CFG::apiprefix . 'networks' => sub {
         my $env = shift;
         my $req = Plack::Request->new($env);
         
         return iterate_and_push
             ($cb,
              'SELECT META().id,block_num,block_time,irreversible,network ' .
              'FROM ' . $CFG::bucket . ' WHERE type=\'sync\'');
     });


$builder->mount
    ($CFG::apiprefix . 'contracts' => sub {
         my $env = shift;
         my $req = Plack::Request->new($env);
         my $p = $req->parameters();
         my $network = $p->{'network'};
         return(error($req, "'network' is not specified")) unless defined($network);
         return(error($req, "invalid network")) unless ($network =~ /^\w+$/);

         my $ctype_filter = '';
         my $ctype = $p->{'contract_type'};
         if( defined($ctype) )
         {
             return(error($req, "invalid contract_type")) unless ($ctype =~ /^\w+$/);
             $ctype_filter = ' AND contract_type=\'' . $ctype . '\' ';
         }
         
         return iterate_and_push
             ($cb,
              'SELECT META().id, account_name, contract_type, track_tables, ' .
              'track_tx, block_timestamp, block_num ' .
              'FROM ' . $CFG::bucket . ' WHERE type=\'contract\' AND network=\'' . $network . '\'' .
              $ctype_filter);
     });


$builder->mount
    ($CFG::apiprefix . 'contract_tables' => sub {
         my $env = shift;
         my $req = Plack::Request->new($env);
         my $p = $req->parameters();
         my $network = $p->{'network'};
         return(error($req, "'network' is not specified")) unless defined($network);
         return(error($req, "invalid network")) unless ($network =~ /^\w+$/);

         my $code = $p->{'code'};
         return(error($req, "'code' is not specified")) unless defined($code);
         return(error($req, "invalid code")) unless ($code =~ /^[1-5a-z.]{1,13}$/);
         
         return iterate_and_push
             ($cb,
              'SELECT distinct tblname ' .
              'FROM ' . $CFG::bucket . ' WHERE (type=\'table_row\' OR type=\'table_upd\') ' .
              ' AND network=\'' . $network . '\' AND code=\'' . $code . '\'' );
     });


$builder->mount
    ($CFG::apiprefix . 'table_scopes' => sub {
         my $env = shift;
         my $req = Plack::Request->new($env);
         my $p = $req->parameters();
         my $network = $p->{'network'};
         return(error($req, "'network' is not specified")) unless defined($network);
         return(error($req, "invalid network")) unless ($network =~ /^\w+$/);

         my $code = $p->{'code'};
         return(error($req, "'code' is not specified")) unless defined($code);
         return(error($req, "invalid code")) unless ($code =~ /^[1-5a-z.]{1,13}$/);

         my $table = $p->{'table'};
         return(error($req, "'table' is not specified")) unless defined($table);
         return(error($req, "invalid table")) unless ($table =~ /^[1-5a-z.]{1,13}$/);
         
         return iterate_and_push
             ($cb,
              'SELECT distinct scope ' .
              'FROM ' . $CFG::bucket . ' WHERE (type=\'table_row\' OR type=\'table_upd\') ' .
              ' AND network=\'' . $network . '\' AND code=\'' . $code . '\' ' .
              ' AND tblname=\'' . $table . '\'');
     });


$builder->mount
    ($CFG::apiprefix . 'table_rows' => sub {
         my $env = shift;
         my $req = Plack::Request->new($env);
         my $p = $req->parameters();
         my $network = $p->{'network'};
         return(error($req, "'network' is not specified")) unless defined($network);
         return(error($req, "invalid network")) unless ($network =~ /^\w+$/);

         my $code = $p->{'code'};
         return(error($req, "'code' is not specified")) unless defined($code);
         return(error($req, "invalid code")) unless ($code =~ /^[1-5a-z.]{1,13}$/);

         my $table = $p->{'table'};
         return(error($req, "'table' is not specified")) unless defined($table);
         return(error($req, "invalid table")) unless ($table =~ /^[1-5a-z.]{1,13}$/);

         my $scope = $p->{'scope'};
         return(error($req, "'scope' is not specified")) unless defined($scope);
         return(error($req, "invalid scope")) unless ($scope =~ /^[1-5a-z.]{1,13}$/);
         
         return iterate_and_push
             ($cb,
              'SELECT block_num,primary_key,rowval ' .
              'FROM ' . $CFG::bucket . ' WHERE type=\'table_row\' ' .
              ' AND network=\'' . $network . '\' AND code=\'' . $code . '\' ' .
              ' AND tblname=\'' . $table . '\' AND scope=\'' . $scope . '\' ' .
              'UNION ALL (SELECT block_num,primary_key,rowval ' .
              'FROM ' . $CFG::bucket . ' WHERE type=\'table_upd\' ' .
              ' AND network=\'' . $network . '\' AND code=\'' . $code . '\' ' .
              ' AND tblname=\'' . $table . '\' AND scope=\'' . $scope . '\' AND added=\'true\') ' .
              'ORDER BY TONUM(block_num)');
     });


$builder->mount
    ($CFG::apiprefix . 'table_row_by_pk' => sub {
         my $env = shift;
         my $req = Plack::Request->new($env);
         my $p = $req->parameters();
         my $network = $p->{'network'};
         return(error($req, "'network' is not specified")) unless defined($network);
         return(error($req, "invalid network")) unless ($network =~ /^\w+$/);

         my $code = $p->{'code'};
         return(error($req, "'code' is not specified")) unless defined($code);
         return(error($req, "invalid code")) unless ($code =~ /^[1-5a-z.]{1,13}$/);

         my $table = $p->{'table'};
         return(error($req, "'table' is not specified")) unless defined($table);
         return(error($req, "invalid table")) unless ($table =~ /^[1-5a-z.]{1,13}$/);

         my $scope = $p->{'scope'};
         return(error($req, "'scope' is not specified")) unless defined($scope);
         return(error($req, "invalid scope")) unless ($scope =~ /^[1-5a-z.]{1,13}$/);

         my $pk = $p->{'pk'};
         return(error($req, "'pk' is not specified")) unless defined($pk);
         return(error($req, "invalid pk")) unless ($pk =~ /^\d+$/);

         my $ret = undef;
         my $rv = $cb->query_slurp
             ('SELECT block_num,primary_key,rowval ' .
              'FROM ' . $CFG::bucket . ' WHERE type=\'table_row\' ' .
              ' AND network=\'' . $network . '\' AND code=\'' . $code . '\' ' .
              ' AND tblname=\'' . $table . '\' AND scope=\'' . $scope . '\' ' .
              ' AND primary_key=\'' . $pk . '\'');

         # there's only one or zero rows
         foreach my $row (@{$rv->rows})
         {
             $ret = $row;
         }

         # process updates
         $rv = $cb->query_slurp
             ('SELECT added,block_num,primary_key,rowval ' .
              'FROM ' . $CFG::bucket . ' WHERE type=\'table_upd\' ' .
              ' AND network=\'' . $network . '\' AND code=\'' . $code . '\' ' .
              ' AND tblname=\'' . $table . '\' AND scope=\'' . $scope . '\' ' .
              ' AND primary_key=\'' . $pk . '\' ORDER BY TONUM(block_num_x)');

         foreach my $row (@{$rv->rows})
         {
             if( $row->{'added'} eq 'true' )
             {
                 delete $row->{'added'};
                 $ret = $row;
             }
             else
             {
                 $ret = undef;
             }
         }
         
         return push_one_or_nothing($ret);
     });





$builder->to_app;



# Local Variables:
# mode: cperl
# indent-tabs-mode: nil
# cperl-indent-level: 4
# cperl-continued-statement-offset: 4
# cperl-continued-brace-offset: -4
# cperl-brace-offset: 0
# cperl-label-offset: -2
# End:

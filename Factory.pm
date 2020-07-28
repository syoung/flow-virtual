use MooseX::Declare;

use strict;
use warnings;

#### USE LIB FOR INHERITANCE
use FindBin qw($Bin);
use lib "$Bin/../";

class Virtual {

sub new {
    my $class      = shift;
    my $type       = shift;
    
    $type = uc(substr($type, 0, 1)) . substr($type, 1);
    
    my $location    = "Virtual/$type/Main.pm";
    $class          = "Virtual::" . $type . "::Main";

    # print "***************** Virtual::new    class: $class\n";
    # print "***************** Virtual::new    location: $location\n";

    require $location;

    return $class->new(@_);
}
    
Virtual->meta->make_immutable(inline_constructor => 0);

} #### END

1;


#import "MainViewController.h"
#import "DDCometClient.h"
#import "DDCometMessage.h"
#import <Reachability/Reachability.h>

@interface MainViewController ()

@property (weak, nonatomic) IBOutlet UIButton *sendButton;
@property (weak, nonatomic) IBOutlet UIButton *connectButton;

@property (nonatomic, copy) NSString * token;
@property (nonatomic, strong) Reachability * reachability;

@end

@implementation MainViewController

#define BASE_URL @"http://localhost:8080/"

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    if (cometClient== nil)
        {
        cometClient = [[DDCometClient alloc] initWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"%@cometd", BASE_URL]]];
        cometClient.delegate = self;
        cometClient.supportedTransports =  DDCometWebSocketSupportedTransport | DDCometLongPollingSupportedTransport;
        
        [cometClient addObserver:self forKeyPath:@"state" options:(NSKeyValueObservingOptionNew) context:nil];
        }
    
    self.connectButton.titleLabel.text = @"Connect";
    self.sendButton.enabled = NO;
    self.textField.enabled = NO;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
    
    if (self.reachability == nil)
        {
        Reachability* reach = [Reachability reachabilityForInternetConnection];
        
        // Set the blocks
        reach.reachableBlock = ^(Reachability*reach)
        {
        // keep in mind this is called on a background thread
        // and if you are updating the UI it needs to happen
        // on the main thread, like this:
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.token length] > 0 &&
                (cometClient.state == DDCometStateDisconnected || cometClient.state == DDCometStateTransportError || cometClient.state == DDCometStateDisconnecting))
                {
                [cometClient handshake];
                }
            NSLog(@"REACHABLE!");
        });
        };
        
        reach.unreachableBlock = ^(Reachability*reach)
        {
            if (cometClient != nil)
                {
                [cometClient disconnect];
                }
        NSLog(@"NOT REACHABLE!");
        };
        
        self.reachability = reach;
        }
    
    // Start the notifier, which will cause the reachability object to retain itself!
    [self.reachability startNotifier];
}


- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIKeyboardWillHideNotification object:nil];
    
    [self.reachability stopNotifier];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation
{
    return interfaceOrientation == UIInterfaceOrientationPortrait;
}

- (IBAction)connectButtonTouched:(id)sender
{
    if (cometClient.state == DDCometStateDisconnected || cometClient.state == DDCometStateTransportError)
        {
        [cometClient handshake];
        }
    else
        {
        [cometClient disconnect];
        }
}



- (IBAction)sendButtonTouched:(id)sender {
    [self textFieldShouldReturn:_textField];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if ([keyPath isEqualToString:@"state"])
        {
        NSNumber * value = [change objectForKeyedSubscript:NSKeyValueChangeNewKey];
        NSString * status = @"";
        DDCometState state = (DDCometState)value.integerValue;
        switch (state) {
            case DDCometStateDisconnected:
                status = @"DDCometStateDisconnected";
                break;
            case DDCometStateConnected:
                status = @"DDCometStateConnected";
                break;
            case DDCometStateConnecting:
                status = @"DDCometStateConnecting";
                break;
            case DDCometStateDisconnecting:
                status = @"DDCometStateDisconnecting";
                break;
            case DDCometStateHandshaking:
                status = @"DDCometStateHandshaking";
                break;
            case DDCometStateTransportError:
                status = @"DDCometStateTransportError";
                break;

            default:
                break;
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            self.textView.text =  [self.textView.text stringByAppendingString:[NSString stringWithFormat:@"[%@]\n", status]];
            if (state == DDCometStateConnected || state == DDCometStateConnecting)
                {
                self.textField.enabled = YES;
                self.sendButton.enabled = YES;
                [self.connectButton setTitle: @"Disconnect" forState: UIControlStateNormal];
                }
            else if (state == DDCometStateDisconnected || state == DDCometStateTransportError)
                {
                self.textField.enabled = NO;
                self.sendButton.enabled = NO;
                [self.connectButton setTitle: @"Connect" forState: UIControlStateNormal];
                }
        });
        
        }
                       
}

#pragma mark -

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
	NSDictionary *data = [NSDictionary dictionaryWithObjectsAndKeys:_textField.text, @"chat", @"iPhone user", @"user", nil];
	[cometClient publishData:data toChannel:@"/chat/demo"];
	
	_textField.text = @"";
	return YES;
}

- (void)appendText:(NSString *)text
{
	_textView.text = [_textView.text stringByAppendingFormat:@"%@\n", text];
}

#pragma mark -

- (void)cometClientHandshakeDidSucceed:(DDCometClient *)client
{
	NSLog(@"Handshake succeeded");

	[self appendText:@"[connected]"];
	
	[client subscribeToChannel:@"/chat/demo" target:self selector:@selector(chatMessageReceived:)];
	[client subscribeToChannel:@"/members/demo" target:self selector:@selector(membershipMessageReceived:)];
	
	NSDictionary *data = [NSDictionary dictionaryWithObjectsAndKeys:@"/chat/demo", @"room", @"iPhone user", @"user", nil];
	[cometClient publishData:data toChannel:@"/service/members"];
}

- (void)cometClient:(DDCometClient *)client handshakeDidFailWithError:(NSError *)error
{
	NSLog(@"Handshake failed");
}

- (void)cometClientConnectDidSucceed:(DDCometClient *)client
{
	NSLog(@"Connect succeeded");
}

- (void)cometClient:(DDCometClient *)client connectDidFailWithError:(NSError *)error
{
	NSLog(@"Connect failed");
    //-1005 == Network Connection Lost
    if (error.code == -1005)
        {
        [cometClient handshake];
        }
}

- (void)cometClient:(DDCometClient *)client didFailWithTransportError:(NSError *)error
{
    NSLog(@"didFailWithTransportError");
    //-1005 == Network Connection Lost
    if (error.code == -1005)
        {
        [cometClient handshake];
        }
    
}

- (void)cometClient:(DDCometClient *)client subscriptionDidSucceed:(DDCometSubscription *)subscription
{
	NSLog(@"Subsription succeeded");
}

- (void)cometClient:(DDCometClient *)client subscription:(DDCometSubscription *)subscription didFailWithError:(NSError *)error
{
	NSLog(@"Subsription failed");
}

- (void)chatMessageReceived:(DDCometMessage *)message
{
	if (message.successful == nil)
		[self appendText:[NSString stringWithFormat:@"%@: %@", [message.data objectForKey:@"user"], [message.data objectForKey:@"chat"]]];
	else if (![message.successful boolValue])
		[self appendText:@"Unable to send message"];
}

- (void)membershipMessageReceived:(DDCometMessage *)message
{
	if ([message.data isKindOfClass:[NSDictionary class]])
		[self appendText:[NSString stringWithFormat:@"[%@ are in the chat]", [message.data objectForKey:@"user"]]];
	if ([message.data isKindOfClass:[NSArray class]])
		[self appendText:[NSString stringWithFormat:@"[%@ are in the chat]", [message.data componentsJoinedByString:@", "]]];
}

#pragma mark - keyboard movements
- (void)keyboardWillShow:(NSNotification *)notification
{
    CGSize keyboardSize = [[[notification userInfo] objectForKey:UIKeyboardFrameBeginUserInfoKey] CGRectValue].size;
    
    [UIView animateWithDuration:0.3 animations:^{
        CGRect f = self.view.frame;
        f.origin.y = -keyboardSize.height;
        self.view.frame = f;
    }];
}

-(void)keyboardWillHide:(NSNotification *)notification
{
    [UIView animateWithDuration:0.3 animations:^{
        CGRect f = self.view.frame;
        f.origin.y = 0.0f;
        self.view.frame = f;
    }];
}
@end

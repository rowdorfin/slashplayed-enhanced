// The touch button explicitly opens chat with Return. As in spkeyboard.m's a90de87 implementation,
// a separate responder owns the system keyboard, and Done is a plain button on an accessory view.
@interface SPTouchChat : NSObject <UITextFieldDelegate>
- (instancetype)initWithHost:(UIView *)host;
- (void)open;
- (void)close;
- (void)cancel;
@end

@implementation SPTouchChat {
    __weak UIView *_host;
    UITextField *_field;
}

static void sp_chat_key(unsigned usage, NSString *characters) {
    // Use the same AppKit mapping as UIKey, without recording what was typed in chat.
    for (NSUInteger i = 0; i < 2; i++) {
        SPEvent *event = sp_event(i == 0 ? SPKeyDown : SPKeyUp);
        event->keyCode = usage ? sp_hid_to_mac[usage] : 0x6C;
        event->characters = event->charactersIgnoringModifiers = characters;
        event->modifierFlags = 0;
        sp_post_quiet(event);
    }
}

static unsigned sp_chat_usage(NSString *character) {
    if (character.length != 1) return 0;
    unichar c = [character characterAtIndex:0];
    if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
    if (c >= 'a' && c <= 'z') return 0x04 + c - 'a';
    if (c >= '1' && c <= '9') return 0x1E + c - '1';
    if (c == '0') return 0x27;
    if (c == ' ') return 0x2C;
    return 0;
}

- (instancetype)initWithHost:(UIView *)host {
    if (!(self = [super init])) return nil;
    _host = host;
    return self;
}

- (void)open {
    if (_field) { [self cancel]; return; }
    if (!_host.window) return;
    _field = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 1, 1)];
    _field.alpha = 0.01;
    _field.delegate = self;
    _field.accessibilityElementsHidden = YES;
    _field.autocorrectionType = UITextAutocorrectionTypeNo;
    _field.spellCheckingType = UITextSpellCheckingTypeNo;
    _field.returnKeyType = UIReturnKeySend;
    _field.smartQuotesType = UITextSmartQuotesTypeNo;
    _field.smartDashesType = UITextSmartDashesTypeNo;

    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, _host.bounds.size.width, 44)];
    bar.backgroundColor = [UIColor colorWithWhite:0.1 alpha:1];
    UIButton *done = [[UIButton alloc] initWithFrame:CGRectMake(8, 0, 100, 44)];
    [done setTitle:@"Concluir" forState:UIControlStateNormal];
    [done addTarget:self action:@selector(cancel) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:done];
    _field.inputAccessoryView = bar;
    _field.text = @" ";
    [_host addSubview:_field];
    if ([_field becomeFirstResponder]) sp_chat_key(0x28, @"\r");
    else [self close];
}

- (void)cancel {
    if (_field.isFirstResponder) sp_chat_key(0x29, @"\033");
    [self close];
}

- (void)close {
    if (!_field) return;
    [_field resignFirstResponder];
    [_field removeFromSuperview];
    _field = nil;
    [_host becomeFirstResponder];
}

- (BOOL)textField:(UITextField *)field shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string {
    // Leave a sentinel so Delete is still delivered when the UIKit field would otherwise be empty.
    if (!string.length) sp_chat_key(0x2A, @"\177");
    [string enumerateSubstringsInRange:NSMakeRange(0, string.length)
                              options:NSStringEnumerationByComposedCharacterSequences
                           usingBlock:^(NSString *character, NSRange substringRange, NSRange enclosingRange, BOOL *stop) {
        sp_chat_key(sp_chat_usage(character), character);
    }];
    field.text = @" ";
    return NO;
}

- (BOOL)textFieldShouldReturn:(UITextField *)field {
    sp_chat_key(0x28, @"\r");
    [self close];
    return NO;
}
@end

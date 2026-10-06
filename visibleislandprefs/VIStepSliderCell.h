#import <Preferences/PSSliderTableCell.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// PSSliderTableCell that quantises to a fixed step (default 0.5 pt) and shows
/// the live value on the right, so geometry trimming is reproducible.
@interface VIStepSliderCell : PSSliderTableCell
@property (nonatomic, assign) float step;
@end

NS_ASSUME_NONNULL_END

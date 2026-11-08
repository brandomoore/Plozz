#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// A recognized first-play region predicate, or zero when inference is inconclusive.
FOUNDATION_EXPORT unsigned HDMVPreferredRegion(NSData *index, NSData *objects);
NS_ASSUME_NONNULL_END

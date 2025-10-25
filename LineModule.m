/*
 * This file is part of LiveWallpaper – LiveWallpaper App for macOS.
 * Copyright (C) 2025 Bios thusvill
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */
#import "LineModule.h"

@implementation LineModule {
  BOOL _needsLayoutUpdate;
  NSSize _cachedIntrinsicSize;
}

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    _needsLayoutUpdate = YES;
    _cachedIntrinsicSize = NSZeroSize;
  }
  return self;
}


- (BOOL)isFlipped {
  return YES;
}


- (NSSize)intrinsicContentSize {
  if (_needsLayoutUpdate) {
    [self recalculateLayout];
  }
  return _cachedIntrinsicSize;
}

- (void)recalculateLayout {
  CGFloat currentX = 0.0;
  CGFloat maxHeight = 0.0;

  // First pass: determine ideal sizes.
  NSMutableArray<NSValue *> *sizes =
      [NSMutableArray arrayWithCapacity:self.subviews.count];
  for (NSView *view in self.subviews) {
    NSSize size = [view fittingSize];
    if (size.width <= 0 || size.height <= 0) {
      size = view.frame.size;
    }
    [sizes addObject:[NSValue valueWithSize:size]];
    if (size.height > maxHeight) {
      maxHeight = size.height;
    }
  }

  // Second pass: position views.
  NSUInteger idx = 0;
  for (NSView *view in self.subviews) {
    NSSize size = sizes[idx].sizeValue;
    [view setFrameSize:size];

    CGFloat yOffset = maxHeight > 0 ? (maxHeight - size.height) / 2.0 : 0.0;
    [view setFrameOrigin:NSMakePoint(currentX, yOffset)];
    currentX += size.width;
    if (idx < self.subviews.count - 1) {
      currentX += 8.0; // horizontal spacing between entries
    }
    idx++;
  }

  NSSize newSize = NSMakeSize(currentX, maxHeight);
  if (!NSEqualSizes(newSize, _cachedIntrinsicSize)) {
    _cachedIntrinsicSize = newSize;
    [self invalidateIntrinsicContentSize];
  }

  _needsLayoutUpdate = NO;
}

- (void)layout {
  [super layout];
  if (_needsLayoutUpdate) {
    [self recalculateLayout];
  }
}


- (void)add:(NSView *)view {
  if (!view) return;

  [self addSubview:view];
  _cachedIntrinsicSize = NSZeroSize;
  _needsLayoutUpdate = YES;

  [self setNeedsLayout:YES];
  [self invalidateIntrinsicContentSize];
}

- (BOOL)mouseDownCanMoveWindow {
  return NO;
}

- (BOOL)isOpaque {
  return NO;
}

- (BOOL)acceptsFirstResponder {
  return NO;
}

@end

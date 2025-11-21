import math
import numpy as np

def downscale(image, new_h, new_w):
    img_height, img_width = image.shape[:2] # Unicamente ancho y altura

    resized = np.empty([new_h, new_w])

    x_ratio = float(img_width - 1) / (new_w - 1)
    y_ratio = float(img_height - 1) / (new_h - 1)

    for i in range(new_h):
        for j in range(new_w):

            x_l, y_l = math.floor(x_ratio * j), math.floor(y_ratio * i)
            x_h, y_h = math.ceil(x_ratio * j), math.ceil(y_ratio * i)

            x_weight = (x_ratio * j) - x_l
            y_weight = (y_ratio * i) - y_l

            a = image[y_l, x_l]
            b = image[y_l, x_h]
            c = image[y_h, x_l]
            d = image[y_h, x_h]

            pixel = a * (1 - x_weight) * (1 - y_weight) + b * x_weight * (1 - y_weight) + c * y_weight * (1 - x_weight) + d * x_weight * y_weight

            resized[i][j] = pixel

    return resized
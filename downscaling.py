import math
import numpy as np
from PIL import Image

# Realiza el downscaling mediante interpolacion bilineal de un array 2D de numpy
def downscale(image, scale):
    img_height, img_width = image.shape[:2] # Unicamente ancho y altura
    new_h, new_w = round(img_height * scale), round(img_width * scale)

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

            resized[i][j] = round(pixel)

    return resized

# Imagen a probar
image = np.array([[0, 64, 128, 192],
         [32, 96, 160, 224],
         [64, 128, 192, 255],
         [96, 160, 224, 255]])

scale = 0.5

print("Array 2D original: ")
print(image)

result = downscale(image, scale)
print(f"Resultante con escala {scale}:")
print(result)

# Calculo de downscaling y exportacion de imagenes
out_image = Image.fromarray(result.astype(np.uint8))
image = Image.fromarray(image.astype(np.uint8))
image.save('test-images/in.jpg')
out_image.save('test-images/out.jpg')